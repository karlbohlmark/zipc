const std = @import("std");
const builtin = @import("builtin");

const queue = @import("./queue.zig");
const QueueLengthType = queue.LengthType;
const os = @import("os.zig");
const constants = @import("./constants.zig");

const ZipcName = [39:0]u8;

const log = std.log.scoped(.zipc);

pub fn sockAddrFromName(name: []const u8) struct { std.os.linux.sockaddr.un, usize } {
    var addr = std.os.linux.sockaddr.un{
        .family = @intCast(std.os.linux.AF.UNIX),
        .path = undefined, // This will be filled below
    };
    addr.path[0] = 0;
    std.mem.copyForwards(u8, addr.path[1..addr.path.len], name);
    return .{ addr, name.len + 1 + @sizeOf(@TypeOf(addr.family)) };
}

const ZipcControlMethod = enum(u8) {
    Connect,
    Disconnect,
};

const ZipcConnectionMode = enum(u8) {
    Server,
    Client,
};

const Queue = queue.Queue;

pub const ZipcParams = extern struct {
    message_size: u32,
    queue_size: QueueLengthType,
};

const ZipcServer = struct {
    name: []const u8,

    abstract_domain_socket: std.os.linux.fd_t,
};

comptime {
    std.debug.assert(88 == @sizeOf(ZipcServerSender));
    std.debug.assert(@sizeOf(ZipcServerSender) == @sizeOf(ZipcClientReceiver));
}

pub const ZipcServerSender = extern struct {
    const Self = @This();
    server_id: u64,
    connection_mode: ZipcConnectionMode = ZipcConnectionMode.Server,
    padding: [7]u8 = undefined,
    name: ZipcName,
    params: ZipcParams,
    /// Null only in a context produced by a failed create (see the C API
    /// wrappers in root.zig); send() on such a context returns false.
    queue: ?*queue.Queue,
    buffers: ?[*]u8,
    init_flag: ?*i32,

    /// Copies `message` into the next slot and publishes it to the receiver.
    ///
    /// Returns false, having published nothing, when the message does not fit
    /// `params.message_size`, the queue is full, or the context is invalid.
    /// `message` must not alias the channel's own buffer region.
    pub fn send(self: *Self, message: []const u8) bool {
        const q = self.queue orelse return false;
        // Checked before anything else so a rejected message never touches
        // shared memory. Slots are message_size bytes and are not guarded by a
        // redzone: the last slot is followed by the init flag and then the end
        // of the mapping.
        if (message.len > self.params.message_size) {
            @branchHint(.unlikely);
            log.debug("rejecting {}-byte message, message_size is {}", .{ message.len, self.params.message_size });
            return false;
        }

        // Claim the slot before writing into it. When the queue is full the
        // next slot is the one the consumer is currently holding a pointer to,
        // so copying first and asking afterwards corrupts a message that has
        // already been delivered.
        const next_index = q.reserve(self.params.queue_size) orelse {
            @branchHint(.unlikely);
            return false;
        };

        // usize math: at video-scale configs (megabyte slots) the byte offset
        // does not fit in u32.
        const start_offset = @as(usize, next_index) * @as(usize, self.params.message_size);
        const slot = (self.buffers.?)[start_offset..][0..message.len];
        @memcpy(slot, message);
        q.commit(self.params.queue_size, next_index, message.len);

        if (builtin.target.os.tag == .linux) {
            // Wake only when a consumer is actually parked in futex_wait.
            // commit()'s seq_cst tail store is ordered before this seq_cst
            // load, and the consumer registers in `waiters` (seq_cst RMW)
            // before the kernel re-checks tail against its expected value -
            // so either we observe the registration, or the consumer observes
            // the new tail and does not sleep.
            if (@atomicLoad(u32, &q.waiters, .seq_cst) != 0) {
                @branchHint(.unlikely);
                _ = std.os.linux.futex_3arg(@ptrCast(&q.tail), .{ .cmd = .WAKE, .private = false }, 1);
            }
        }
        return true;
    }

    pub fn init(name: [*:0]const u8, shared_mem_ptr: [*]align(8) u8, queue_size: QueueLengthType, message_size: u32, server_id: u64) ZipcServerSender {
        const name_slice = std.mem.span(name);
        if (name_slice.len >= 40) {
            @panic("name length cannot be longer than 39");
        }
        var dest_name: ZipcName = undefined;
        std.mem.copyForwards(u8, dest_name[0..name_slice.len], name_slice);
        dest_name[name_slice.len] = 0;
        const queue_byte_size: usize = queueByteSize(queue_size);
        const init_flag_ptr: *i32 = @ptrFromInt(@intFromPtr(shared_mem_ptr) + initFlagOffset(queue_size, message_size));
        const q: *Queue = @ptrCast(@alignCast(shared_mem_ptr));
        if (@atomicLoad(i32, init_flag_ptr, .acquire) != constants.ZIPC_MAGIC) {
            q.init();
            @atomicStore(i32, init_flag_ptr, constants.ZIPC_MAGIC, .release);
        }
        return .{
            .server_id = server_id,
            .connection_mode = ZipcConnectionMode.Server,
            .name = dest_name,
            .params = .{
                .message_size = message_size,
                .queue_size = queue_size,
            },
            .queue = q,
            .buffers = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size),
            .init_flag = init_flag_ptr,
        };
    }

    pub fn dumpHex(self: *Self) void {
        if (self.queue == null) return;
        const mem_pointer = self.getSharedMemoryPointer();
        log.debug("dump hex from sender", .{});
        std.debug.dumpHex(mem_pointer[0..self.getSharedMemorySize()]);
    }

    pub fn dumpQueueHex(self: *Self) void {
        if (self.queue == null) return;
        const queue_size_bytes = queueByteSize(self.params.queue_size);
        log.debug("dump queue hex ({}) from sender", .{queue_size_bytes});
        const mem_pointer = self.getSharedMemoryPointer();
        std.debug.dumpHex(mem_pointer[0..queue_size_bytes]);
    }

    pub fn getSharedMemorySize(self: *Self) usize {
        return computeSharedMemorySize(self.params.queue_size, self.params.message_size);
    }

    /// Asserts a valid context: unlike send(), this panics on a context
    /// whose create failed or that was destroyed.
    pub fn getSharedMemoryPointer(self: *Self) [*]align(8) u8 {
        return @ptrCast(@alignCast(self.queue.?));
    }
};

const ZipcClientConnectRequest = struct {
    method: ZipcControlMethod = ZipcControlMethod.Connect,
    params: ZipcParams,
};
pub const ZipcClientReceiver = extern struct {
    const Self = @This();

    client_id: u64,
    connection_mode: ZipcConnectionMode = ZipcConnectionMode.Client,
    padding: [7]u8 = undefined,
    name: ZipcName,
    params: ZipcParams = undefined,
    /// Null only in a context produced by a failed create (see the C API
    /// wrappers in root.zig); receive() on such a context returns null.
    queue: ?*queue.Queue,
    buffers: ?[*]align(8) u8, // [queue_size_param][message_size_param]u8
    init_flag: ?*i32,

    pub fn connect(self: *Self) ZipcClientConnectRequest {
        return .{
            .method = ZipcControlMethod.Connect,
            .params = self.params,
        };
    }

    /// Builds the slice for a dequeued slot. The stored length comes out of
    /// shared memory, so it is clamped rather than trusted: a peer built
    /// against different params, or a segment left over from an older run,
    /// would otherwise hand the caller a slice running past the mapping.
    inline fn messageSlice(self: *Self, index: QueueLengthType, stored_len: queue.ValueType) []u8 {
        const len: usize = @intCast(@min(stored_len, @as(queue.ValueType, self.params.message_size)));
        const start = @as(usize, index) * @as(usize, self.params.message_size);
        return (self.buffers.?)[start..][0..len];
    }

    /// Returns the slot index and a slice pointing into shared memory. The
    /// message is not copied.
    ///
    /// The slice is valid until the next receive() or receive_blocking() call
    /// on this receiver. Until then `head` does not move, so the producer's
    /// reserve() cannot hand this slot back out and it reports a full queue
    /// instead of lapping the reader. The next receive releases the slot, and
    /// the producer may overwrite it from that point on.
    ///
    /// So processing a message before asking for the next one needs no copy;
    /// retaining the slice past the next receive - collecting a batch of them,
    /// or passing one to another thread - does.
    pub fn receive(self: *Self) ?struct { QueueLengthType, []u8 } {
        const q = self.queue orelse return null;
        var current_tail: QueueLengthType = 0;
        if (q.dequeue(self.params.queue_size, &current_tail)) |item| {
            const index, const val = item;
            return .{ index, self.messageSlice(index, val) };
        }
        return null;
    }

    /// Waits up to `timeout_ms` (0..65535) for a message. The returned slice
    /// has the same lifetime as receive()'s: valid until the next receive
    /// call on this receiver.
    pub fn receive_blocking(self: *Self, timeout_ms: u16) ?struct { QueueLengthType, []u8 } {
        const q = self.queue orelse return null;
        const start_ns = os.monotonicNanos();
        const deadline_ns: u64 = start_ns + @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (true) {
            var current_tail: QueueLengthType = 0;
            if (q.dequeue(self.params.queue_size, &current_tail)) |item| {
                const index, const val = item;
                return .{ index, self.messageSlice(index, val) };
            }
            const now_ns = os.monotonicNanos();
            if (now_ns >= deadline_ns) return null;
            const remaining_ns = deadline_ns - now_ns;
            if (builtin.target.os.tag == .linux) {
                // Register before waiting; commit()'s seq_cst store and this
                // seq_cst RMW pair up so the producer cannot both miss the
                // registration and have its tail store go unseen. The kernel
                // re-checks tail against current_tail under the futex lock,
                // so a commit landing between our dequeue and the wait makes
                // the wait return immediately (EAGAIN) instead of sleeping
                // through the wake. Spurious wakeups just re-run the loop.
                q.registerWaiter();
                const timeout_timespec = std.os.linux.timespec{
                    .sec = @intCast(remaining_ns / std.time.ns_per_s),
                    .nsec = @intCast(remaining_ns % std.time.ns_per_s),
                };
                _ = std.os.linux.futex_4arg(@ptrCast(&q.tail), .{ .cmd = .WAIT, .private = false }, @intCast(current_tail), &timeout_timespec);
                q.unregisterWaiter();
            } else {
                // Polling fallback for platforms without futex: sleep in 1ms
                // steps, re-checking tail (atomically) and the deadline.
                var slept: u64 = 0;
                while (slept < remaining_ns and @atomicLoad(QueueLengthType, &q.tail, .acquire) == current_tail) {
                    os.nanosleep(0, 1_000_000);
                    slept += 1_000_000;
                }
            }
        }
    }

    pub fn init(name: [*:0]const u8, shared_mem_ptr: [*]align(8) u8, queue_size: QueueLengthType, message_size: u32, client_id: u64) ZipcClientReceiver {
        const name_slice = std.mem.span(name);
        if (name_slice.len >= 40) {
            @panic("name length cannot be longer than 39");
        }
        var dest_name: ZipcName = undefined;
        std.mem.copyForwards(u8, dest_name[0..name_slice.len], name_slice);
        dest_name[name_slice.len] = 0;
        const queue_byte_size: usize = queueByteSize(queue_size);
        return .{
            .client_id = client_id,
            .connection_mode = ZipcConnectionMode.Client,
            .name = dest_name,
            .params = .{
                .message_size = message_size,
                .queue_size = queue_size,
            },
            .queue = @ptrCast(@alignCast(shared_mem_ptr)),
            .buffers = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size),
            .init_flag = @ptrFromInt(@intFromPtr(shared_mem_ptr) + initFlagOffset(queue_size, message_size)),
        };
    }

    /// Asserts a valid context: unlike receive(), this panics on a context
    /// whose create failed or that was destroyed.
    pub fn getSharedMemoryPointer(self: *Self) [*]align(8) u8 {
        return @ptrCast(@alignCast(self.queue.?));
    }

    pub fn dumpHex(self: *Self) void {
        if (self.queue == null) return;
        const mem_pointer = self.getSharedMemoryPointer();
        log.debug("dump hex from receiver. Pointer: {*}, shared mem size: {}", .{ mem_pointer, self.sharedMemorySize() });
        std.debug.dumpHex(mem_pointer[0..self.sharedMemorySize()]);
    }

    pub fn sharedMemorySize(self: *Self) usize {
        return computeSharedMemorySize(self.params.queue_size, self.params.message_size);
    }

    pub fn dumpQueueHex(self: *Self) void {
        if (self.queue == null) return;
        const QueueType = queue.Queue;
        std.debug.lockStdErr();
        log.debug("dump queue hex ({}) from receiver", .{@sizeOf(QueueType)});
        std.debug.unlockStdErr();
        const mem_pointer = self.getSharedMemoryPointer();
        std.debug.dumpHex(mem_pointer[0..@sizeOf(QueueType)]);
    }
};

/// Total segment size: queue header + per-slot length array + slot buffers +
/// the (aligned) 4-byte init flag. Note the usable capacity is
/// queue_size - 1 slots: the ring keeps one slot unused to distinguish full
/// from empty.
pub fn getSharedMemorySize(queue_size: QueueLengthType, message_size: u32) usize {
    return computeSharedMemorySize(queue_size, message_size);
}

/// Like getSharedMemorySize, but returns null instead of overflowing when
/// the parameters describe a segment larger than the address space.
pub fn checkedSharedMemorySize(queue_size: QueueLengthType, message_size: u32) ?usize {
    const buffers = std.math.mul(usize, queue_size, message_size) catch return null;
    const unaligned = std.math.add(usize, queueByteSize(queue_size), buffers) catch return null;
    const flag_offset = std.math.add(usize, unaligned, @alignOf(i32) - 1) catch return null;
    return std.math.add(usize, flag_offset & ~@as(usize, @alignOf(i32) - 1), @sizeOf(i32)) catch return null;
}

fn computeSharedMemorySize(queue_size: QueueLengthType, message_size: u32) usize {
    return checkedSharedMemorySize(queue_size, message_size) orelse
        @panic("zipc: shared memory size overflows usize");
}

/// Byte offset of the i32 init flag: right after the slot buffers, padded up
/// so it stays 4-aligned when queue_size * message_size is not a multiple
/// of 4.
fn initFlagOffset(queue_size: QueueLengthType, message_size: u32) usize {
    const buffers_end = queueByteSize(queue_size) + @as(usize, queue_size) * @as(usize, message_size);
    return std.mem.alignForward(usize, buffers_end, @alignOf(i32));
}

/// A context whose pointers are all null; what the C API returns when create
/// fails. send/receive/receive_blocking/destroy and the dump helpers are
/// safe no-ops on it; getSharedMemoryPointer asserts and must not be called.
pub fn invalidServerSender() ZipcServerSender {
    return .{
        .server_id = 0,
        .connection_mode = ZipcConnectionMode.Server,
        .padding = std.mem.zeroes([7]u8),
        .name = std.mem.zeroes(ZipcName),
        .params = .{ .message_size = 0, .queue_size = 0 },
        .queue = null,
        .buffers = null,
        .init_flag = null,
    };
}

pub fn invalidClientReceiver() ZipcClientReceiver {
    return .{
        .client_id = 0,
        .connection_mode = ZipcConnectionMode.Client,
        .padding = std.mem.zeroes([7]u8),
        .name = std.mem.zeroes(ZipcName),
        .params = .{ .message_size = 0, .queue_size = 0 },
        .queue = null,
        .buffers = null,
        .init_flag = null,
    };
}

pub fn initServerSenderWithBuffer(
    name: [*:0]const u8,
    shared_memory: [*]align(8) u8,
    queue_size: queue.LengthType,
    message_size: u32,
    server_id: u64,
) ZipcServerSender {
    return ZipcServerSender.init(name, shared_memory, queue_size, message_size, server_id);
}

pub fn initClient(
    name: [*:0]const u8,
    shared_memory: [*]align(8) u8,
    queue_size: queue.LengthType,
    message_size: u32,
    client_id: u64,
) ZipcClientReceiver {
    return ZipcClientReceiver.init(name, shared_memory, queue_size, message_size, client_id);
}

pub fn run_client() !void {
    const thread_id = std.Thread.getCurrentId();
    log.debug("client running in thread {}", .{thread_id});

    const message_size = 1536;
    const queue_size = 128;
    const socket_name = "/well-known-server-name";
    const fd = try os.shm_open(socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0o600);
    defer os.close(fd);
    const shared_memory_size = getSharedMemorySize(queue_size, message_size);
    const shared_mem = try os.mmap(fd, shared_memory_size, 0);
    var ipc_client = initClient(
        socket_name,
        shared_mem.ptr,
        queue_size,
        message_size,
        0, // client_id
    );
    const result = ipc_client.receive();
    if (result) |r| {
        const index, const message_slice = r;
        log.debug("received index {} and slice with length {}: {X}", .{ index, message_slice.len, message_slice });
    }
}

test "client server connection test" {
    const message_size = 1536;
    const queue_size = 128;

    const socket_name = "/well-known-server-name";
    const shared_memory_size = getSharedMemorySize(queue_size, message_size);
    const fd = try os.shm_open(socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0o600);
    defer os.close(fd);
    try os.ftruncate(fd, shared_memory_size);

    const shared_mem_slice = try os.mmap(fd, shared_memory_size, 0);
    const shared_memory: [*]align(8) u8 = shared_mem_slice.ptr;
    shared_memory[0] = 0;
    var server_sender = initServerSenderWithBuffer(
        socket_name,
        shared_memory,
        queue_size,
        message_size,
        0, // server_id
    );
    var some_data = std.mem.zeroes([20]u8);
    some_data[0] = 1;
    some_data[1] = 2;
    some_data[2] = 3;
    const thread_id = std.Thread.getCurrentId();
    log.debug("server running in thread {}", .{thread_id});
    try std.testing.expect(server_sender.send(&some_data));

    var thread = try std.Thread.spawn(.{}, run_client, .{});
    thread.join();
}

fn queueByteSize(length: queue.LengthType) usize {
    return @sizeOf(queue.Queue) + @as(usize, length) * @sizeOf(queue.ValueType);
}
