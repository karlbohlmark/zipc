const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub fn LamportQueueU64(length: u16) type {
    const Queue = extern struct {
        buffer: [length]u64 = undefined,
        head: u32 = 0,
        // padding: [64]u8 = undefined,
        tail: u32 = 0,

        const Self = @This();

        pub fn init(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }

        fn isEmpty(self: *Self) bool {
            return self.head == self.tail;
        }

        pub fn enqueue(self: *Self, value: u64) bool {
            const cur_tail = self.tail; // tail is owned by the producer
            std.debug.print("cur_tail {}\n", .{cur_tail});
            const cur_head = @atomicLoad(u32, &self.head, AtomicOrder.acquire);
            std.debug.print("cur_head (seen by sender) {}\n", .{cur_head});
            if ((cur_tail + 1) % length == cur_head) {
                // Full
                std.debug.print("queue full\n", .{});
                return false;
            }
            std.debug.print("write to queue index {}\n", .{cur_tail});
            self.buffer[cur_tail] = value;
            const next_tail = (cur_tail + 1) % length;
            @atomicStore(u32, &self.tail, next_tail, AtomicOrder.release);
            std.debug.print("setting tail to {}\n", .{next_tail});
            return true;
        }

        pub fn dequeue(self: *Self) struct { u32, u64 } {
            std.debug.print("dequeue\n", .{});
            const cur_tail = @atomicLoad(u32, &self.tail, AtomicOrder.acquire);
            const cur_head = self.head; // head is owned by the consumer
            if (cur_head == cur_tail) {
                // empty
                std.debug.lockStdErr();
                std.debug.print("queue empty, head: {}\n", .{cur_head});
                std.debug.unlockStdErr();
                return .{ 1 << 17, 0 };
            } else {
                std.debug.lockStdErr();
                std.debug.print("queue not empty, head: {}\n", .{cur_head});
                std.debug.unlockStdErr();
            }
            const value: u64 = self.buffer[cur_head];
            const next_head = (cur_head + 1) % length;
            std.debug.print("setting head to {}\n", .{next_head});
            @atomicStore(u32, &self.head, next_head, AtomicOrder.release);
            return .{ cur_head, value };
        }
    };
    return Queue;
}
