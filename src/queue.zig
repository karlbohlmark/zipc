const std = @import("std");
const AtomicOrder = std.builtin.AtomicOrder;

pub const LengthType = u32;
pub const ValueType = u64;

pub const Queue = extern struct {
    head: LengthType = 0,
    padding1: [64 - @sizeOf(LengthType)]u8,
    tail: LengthType = 0,
    /// Number of consumers currently parked in a futex wait on `tail`. Lives
    /// on tail's cache line deliberately: it is only written when a consumer
    /// goes to sleep or wakes up, both of which already cost a syscall.
    waiters: u32 = 0,
    padding2: [64 - @sizeOf(LengthType) - @sizeOf(u32)]u8,

    const Self = @This();

    comptime {
        std.debug.assert(@sizeOf(Queue) == 128);
        std.debug.assert(@offsetOf(Queue, "tail") == 64);
    }

    pub fn init(self: *Self) void {
        // Fresh segments arrive zero-filled from ftruncate, so these stores
        // are belt-and-braces; they are atomic because a receiver that
        // attached first may already be reading. `waiters` is deliberately
        // NOT reset: that receiver may already be registered and parked in
        // futex_wait, and zeroing its registration would lose the wake for
        // the first message (and its later decrement would underflow the
        // counter, permanently disabling wakes).
        @atomicStore(LengthType, &self.head, 0, AtomicOrder.seq_cst);
        @atomicStore(LengthType, &self.tail, 0, AtomicOrder.seq_cst);
    }

    /// Announces a consumer about to park in futex_wait on `tail`. The
    /// seq_cst RMW pairs with commit()'s seq_cst tail store and the
    /// producer's seq_cst load in the skip-the-wake check.
    pub fn registerWaiter(self: *Self) void {
        _ = @atomicRmw(u32, &self.waiters, .Add, 1, AtomicOrder.seq_cst);
    }

    /// Withdraws a registration. Refuses to drive the counter below zero, so
    /// a clobbered counter (e.g. a stale segment written by a foreign
    /// process) degrades to extra wakes rather than wrapping to a huge value.
    pub fn unregisterWaiter(self: *Self) void {
        var observed = @atomicLoad(u32, &self.waiters, AtomicOrder.seq_cst);
        while (observed != 0) {
            observed = @cmpxchgWeak(u32, &self.waiters, observed, observed - 1, AtomicOrder.seq_cst, AtomicOrder.seq_cst) orelse break;
        }
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

    /// Publishes the slot returned by the preceding reserve(). The store to
    /// `tail` pairs with the consumer's acquire in dequeue(), making the
    /// producer's writes to the message buffer visible to the consumer.
    ///
    /// The store is seq_cst rather than release because of the skip-the-wake
    /// optimization: the producer reads `waiters` right after committing, and
    /// the consumer registers in `waiters` (seq_cst RMW) before re-checking
    /// `tail` through the futex expected-value comparison. seq_cst on both
    /// sides forbids the store-load reordering that would let the producer
    /// miss the registration while the consumer misses the new tail - the
    /// classic lost-wakeup interleaving.
    pub fn commit(self: *Self, length: LengthType, index: LengthType, value: ValueType) void {
        self.items(length)[index] = value;
        const next_tail = (index + 1) % length;
        @atomicStore(LengthType, &self.tail, next_tail, AtomicOrder.seq_cst);
    }

    pub fn enqueue(self: *Self, length: LengthType, value: ValueType) bool {
        const index = self.reserve(length) orelse return false;
        self.commit(length, index, value);
        return true;
    }

    pub fn dequeue(self: *Self, length: LengthType, tail_ptr: *LengthType) ?struct { LengthType, ValueType } {
        const cur_tail = @atomicLoad(LengthType, &self.tail, AtomicOrder.acquire);
        tail_ptr.* = cur_tail; // Output the current tail, used by futex_wait
        const cur_head = self.head; // head is owned by the consumer
        if (cur_head == cur_tail) {
            // empty
            return null;
        }
        const value: ValueType = self.items(length)[cur_head];
        const next_head = (cur_head + 1) % length;
        @atomicStore(LengthType, &self.head, next_head, AtomicOrder.release);
        return .{ cur_head, value };
    }
};

const testing = std.testing;

fn testQueue(backing: []align(8) u8) *Queue {
    const q: *Queue = @ptrCast(@alignCast(backing.ptr));
    q.init();
    return q;
}

test "capacity is length - 1" {
    const length = 8;
    var backing: [@sizeOf(Queue) + length * @sizeOf(ValueType)]u8 align(8) = undefined;
    const q = testQueue(&backing);

    var i: ValueType = 0;
    while (i < length - 1) : (i += 1) {
        try testing.expect(q.enqueue(length, i));
    }
    try testing.expect(!q.enqueue(length, 999));

    var tail: LengthType = 0;
    _, const first = q.dequeue(length, &tail) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(ValueType, 0), first);
    // One slot freed: exactly one more enqueue fits.
    try testing.expect(q.enqueue(length, 100));
    try testing.expect(!q.enqueue(length, 999));
}

test "fifo order across wraparound" {
    const length = 4;
    var backing: [@sizeOf(Queue) + length * @sizeOf(ValueType)]u8 align(8) = undefined;
    const q = testQueue(&backing);

    var next_in: ValueType = 0;
    var next_out: ValueType = 0;
    var tail: LengthType = 0;
    // Push/pop enough to wrap the ring many times, two at a time.
    while (next_in < 100) {
        try testing.expect(q.enqueue(length, next_in));
        next_in += 1;
        try testing.expect(q.enqueue(length, next_in));
        next_in += 1;
        while (q.dequeue(length, &tail)) |item| {
            _, const value = item;
            try testing.expectEqual(next_out, value);
            next_out += 1;
        }
    }
    try testing.expectEqual(next_in, next_out);
}

test "dequeue on empty reports current tail" {
    const length = 4;
    var backing: [@sizeOf(Queue) + length * @sizeOf(ValueType)]u8 align(8) = undefined;
    const q = testQueue(&backing);

    var tail: LengthType = 0;
    try testing.expect(q.dequeue(length, &tail) == null);
    try testing.expectEqual(@as(LengthType, 0), tail);
    try testing.expect(q.enqueue(length, 42));
    try testing.expect(q.dequeue(length, &tail) != null);
    try testing.expectEqual(@as(LengthType, 1), tail);
}
