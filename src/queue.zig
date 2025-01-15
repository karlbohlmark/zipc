const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub const LengthType = u32;
pub const ValueType = u64;

pub fn LamportQueueU64(length: LengthType) type {
    const Queue = extern struct {
        buffer: [length]ValueType = undefined,
        head: LengthType = 0,
        // padding: [64]u8 = undefined,
        tail: LengthType = 0,

        const Self = @This();

        pub fn init(self: *Self) void {
            self.head = 0;
            self.tail = 0;
        }

        fn isEmpty(self: *Self) bool {
            return self.head == self.tail;
        }

        pub fn enqueue(self: *Self, value: ValueType) bool {
            const cur_tail = self.tail; // tail is owned by the producer
            std.debug.print("cur_tail {}\n", .{cur_tail});
            const cur_head = @atomicLoad(LengthType, &self.head, AtomicOrder.acquire);
            std.debug.print("cur_head (seen by sender) {}\n", .{cur_head});
            if ((cur_tail + 1) % length == cur_head) {
                // Full
                std.debug.print("queue full\n", .{});
                return false;
            }
            std.debug.print("write to queue index {}\n", .{cur_tail});
            self.buffer[cur_tail] = value;
            const next_tail = (cur_tail + 1) % length;
            @atomicStore(LengthType, &self.tail, next_tail, AtomicOrder.release);
            std.debug.print("setting tail to {}\n", .{next_tail});
            return true;
        }

        pub fn dequeue(self: *Self, tail_ptr: *LengthType) ?struct { LengthType, ValueType } {
            std.debug.print("dequeue\n", .{});
            const cur_tail = @atomicLoad(LengthType, &self.tail, AtomicOrder.acquire);
            tail_ptr.* = cur_tail; // Output the current tail, used by futex_wait
            const cur_head = self.head; // head is owned by the consumer
            if (cur_head == cur_tail) {
                // empty
                std.debug.lockStdErr();
                std.debug.print("queue empty, head: {}\n", .{cur_head});
                std.debug.unlockStdErr();
                return null;
            } else {
                std.debug.lockStdErr();
                std.debug.print("queue not empty, head: {}\n", .{cur_head});
                std.debug.unlockStdErr();
            }
            const value: ValueType = self.buffer[cur_head];
            const next_head = (cur_head + 1) % length;
            std.debug.print("setting head to {}\n", .{next_head});
            @atomicStore(LengthType, &self.head, next_head, AtomicOrder.release);
            return .{ cur_head, value };
        }
    };
    return Queue;
}
