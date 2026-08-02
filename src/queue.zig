const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub const LengthType = u32;
pub const ValueType = u64;

pub const Queue = extern struct {
    head: LengthType = 0,
    padding1: [64 - @sizeOf(LengthType)]u8,
    // padding: [64]u8 = undefined,
    tail: LengthType = 0,
    padding2: [64 - @sizeOf(LengthType)]u8,

    const Self = @This();

    pub fn init(self: *Self) void {
        self.head = 0;
        self.tail = 0;
    }

    pub fn itemsPtr(self: *Self) [*]ValueType {
        const self_bytes: [*]u8 = @ptrCast(self);
        const items_start = self_bytes + @sizeOf(Self);
        return @ptrCast(@alignCast(items_start));
    }

    pub fn items(self: *Self, length: LengthType) []ValueType {
        return self.itemsPtr()[0..length];
    }

    fn isEmpty(self: *Self) bool {
        return self.head == self.tail;
    }

    /// Claims the next slot for the producer, or returns null if the queue is
    /// full. Nothing is published until the matching commit().
    ///
    /// Callers must reserve before writing into the slot's message buffer, not
    /// after. The ring keeps one slot unused, and when the queue is full that
    /// slot is precisely the one the consumer was most recently handed by
    /// dequeue() - writing into it speculatively would corrupt a message that
    /// has already been delivered.
    ///
    /// The acquire on `head` pairs with the consumer's release in dequeue(),
    /// so the consumer's reads of the previous occupant of this slot are
    /// ordered before the writes the producer is about to make.
    pub fn reserve(self: *Self, length: LengthType) ?LengthType {
        const cur_tail = self.tail; // tail is owned by the producer
        const cur_head = @atomicLoad(LengthType, &self.head, AtomicOrder.acquire);
        if ((cur_tail + 1) % length == cur_head) {
            // Full
            return null;
        }
        return cur_tail;
    }

    /// Publishes the slot returned by the preceding reserve(). The release
    /// pairs with the consumer's acquire on `tail` in dequeue(), making the
    /// producer's writes to the message buffer visible to the consumer.
    pub fn commit(self: *Self, length: LengthType, index: LengthType, value: ValueType) void {
        self.items(length)[index] = value;
        const next_tail = (index + 1) % length;
        @atomicStore(LengthType, &self.tail, next_tail, AtomicOrder.release);
    }

    pub fn enqueue(self: *Self, length: LengthType, value: ValueType) bool {
        const index = self.reserve(length) orelse return false;
        self.commit(length, index, value);
        return true;
    }

    pub fn dequeue(self: *Self, length: LengthType, tail_ptr: *LengthType) ?struct { LengthType, ValueType } {
        // std.debug.print("dequeue\n", .{});
        const cur_tail = @atomicLoad(LengthType, &self.tail, AtomicOrder.acquire);
        tail_ptr.* = cur_tail; // Output the current tail, used by futex_wait
        const cur_head = self.head; // head is owned by the consumer
        if (cur_head == cur_tail) {
            // empty
            // std.debug.lockStdErr();
            // std.debug.print("queue empty, head: {}\n", .{cur_head});
            // std.debug.unlockStdErr();
            return null;
        } else {
            // std.debug.lockStdErr();
            // std.debug.print("queue not empty, head: {}\n", .{cur_head});
            // std.debug.unlockStdErr();
        }
        const value: ValueType = self.items(length)[cur_head];
        const next_head = (cur_head + 1) % length;
        // std.debug.print("setting head to {}\n", .{next_head});
        @atomicStore(LengthType, &self.head, next_head, AtomicOrder.release);
        return .{ cur_head, value };
    }
};
