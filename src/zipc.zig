const std = @import("std");
const builtin = @import("builtin");

const queue = @import("./queue.zig");
const QueueLengthType = queue.LengthType;
const os = @import("os.zig");
const constants = @import("./constants.zig");

const FD = std.os.linux.fd_t;

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
// pub const shared_memory_size = @sizeOf(queue.Queue) + queue_size_param * @sizeOf(queue.ValueType) + message_size_param * queue_size_param + @sizeOf(i32);
// pub const message_size: u32 = message_size_param;
// pub const queue_size: QueueLengthType = queue_size_param;

// Explicit backing integer: this is embedded in the `extern struct` channel
// handles below, which requires a defined signedness.
pub const ZipcParams = packed struct(u64) {
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
    queue: *queue.Queue,
    buffers: [*]u8,
    init_flag: *i32,

    /// Copies `message` into the next slot and publishes it to the receiver.
    ///
    /// Returns false, having published nothing, when the message does not fit
    /// `params.message_size` or the queue is full. `message` must not alias the
    /// channel's own buffer region.
    pub fn send(self: *Self, message: []const u8) bool {
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
        const next_index = self.queue.reserve(self.params.queue_size) orelse {
            @branchHint(.unlikely);
            return false;
        };

        const start_offset = next_index * self.params.message_size;
        const slot = self.buffers[start_offset..][0..message.len];
        // Deliberately an element-wise loop rather than @memcpy. LLVM recognises
        // this idiom and inlines a straight-line AVX-512 copy; @memcpy instead
        // emits a call to the generic xmm-based memcpy that bundle_compiler_rt
        // puts in the archive, which measured ~4ns/msg slower at 1536 bytes.
        for (slot, message) |*d, s| d.* = s;
        self.queue.commit(self.params.queue_size, next_index, message.len);

        if (builtin.target.os.tag == .linux) {
            const wake_return_val = std.os.linux.futex_3arg(@ptrCast(&self.queue.tail), .{ .cmd = .WAKE, .private = false }, 1);
            log.debug("wake_return_val: {}", .{wake_return_val});
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
        // std.debug.lockStdErr();
        // log.debug("dump hex from sender {*}", .{shared_mem_ptr});
        // std.debug.dumpHex(shared_mem_ptr[0..shared_memory_size]);
        // std.debug.unlockStdErr();
        const queue_byte_size: usize = queueByteSize(queue_size);
        const buffers_bytes_size: usize = @as(usize, message_size) * @as(usize, queue_size);
        const init_flag_ptr_int: usize = @intFromPtr(shared_mem_ptr) + queue_byte_size + buffers_bytes_size;
        const init_flag_ptr: *i32 = @ptrFromInt(init_flag_ptr_int);
        // log.debug("init_flag value before init: {}", .{init_flag_ptr.*});
        var q: *Queue = @ptrCast(@alignCast(shared_mem_ptr));
        if (init_flag_ptr.* != constants.ZIPC_MAGIC) {
            q.init();
            @atomicStore(i32, init_flag_ptr, constants.ZIPC_MAGIC, .release);
        }
        // log.debug("will wake", .{});
        // log.debug("init_flag value after init: {}", .{init_flag_ptr.*});
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
        const mem_pointer = self.getSharedMemoryPointer();
        log.debug("dump hex from sender");
        std.debug.dumpHex(mem_pointer[0..self.getSharedMemorySize()]);
    }

    pub fn dumpQueueHex(self: *Self) void {
        const queue_size_bytes = queueByteSize(self.params.queue_size);
        log.debug("dump queue hex ({}) from sender", .{queue_size_bytes});
        const mem_pointer = self.getSharedMemoryPointer();
        std.debug.dumpHex(mem_pointer[0..queue_size_bytes]);
    }

    pub fn getSharedMemorySize(self: *Self) usize {
        // // pub const shared_memory_size = @sizeOf(queue.Queue) + queue_size_param * @sizeOf(queue.ValueType) + message_size_param * queue_size_param + @sizeOf(i32);
        const shared_memory_size = @sizeOf(queue.Queue) + queueByteSize(self.params.queue_size) + self.params.queue_size * self.params.message_size + @sizeOf(i32);
        return shared_memory_size;
    }

    pub fn getSharedMemoryPointer(self: *Self) [*]align(8) u8 {
        return @ptrCast(self.queue);
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
    queue: *queue.Queue,
    buffers: [*]align(8) u8, // [queue_size_param][message_size_param]u8
    init_flag: *i32,

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
        return self.buffers[index * self.params.message_size ..][0..len];
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
        var current_tail: QueueLengthType = 0;
        if (self.queue.dequeue(self.params.queue_size, &current_tail)) |item| {
            const index, const val = item;
            log.debug("received val {}", .{val});
            return .{ index, self.messageSlice(index, val) };
        } else {
            return null;
        }
    }

    /// Waits up to `timeout_ms` for a message. The returned slice has the same
    /// lifetime as receive()'s: valid until the next receive call on this
    /// receiver.
    pub fn receive_blocking(self: *Self, timeout_ms: u16) ?struct { QueueLengthType, []u8 } {
        // self.dumpHex();
        if (timeout_ms >= 1000) {
            @panic("timeout_ms must be less than 1000");
        }
        var current_tail: QueueLengthType = 0;
        if (self.queue.dequeue(self.params.queue_size, &current_tail)) |item| {
            const index, const val = item;
            return .{ index, self.messageSlice(index, val) };
        } else {
            log.debug("queue empty, waiting", .{});
            const timestamp_ms = os.monotonicMillis();
            const timeout_timespec = std.posix.timespec{
                .sec = 0,
                .nsec = @intCast((@as(u32, @intCast(timeout_ms)) % 1000) * 1_000_000),
            };
            if (builtin.target.os.tag == .linux) {
                const futex_return_value = std.os.linux.futex_4arg(@ptrCast(&self.queue.tail), .{ .cmd = .WAIT, .private = false }, @intCast(current_tail), &timeout_timespec);
                if (futex_return_value != 0) {
                    log.debug("futex_wait failed: {}", .{futex_return_value});
                }
            } else {
                while (self.queue.tail == current_tail) {
                    os.nanosleep(0, 1_000_000); // 1ms
                }
            }
            // This could be a spurious wake up, so we check again
            const next = self.receive();
            if (next) |item| {
                return item;
            }
            const elapsed_ms: i64 = os.monotonicMillis() - timestamp_ms;
            if (elapsed_ms < timeout_ms) {
                const remaining_ms: i64 = @as(i64, @intCast(timeout_ms)) - elapsed_ms;
                return self.receive_blocking(@truncate(@abs(remaining_ms)));
            } else {
                log.debug("receive_blocking timed out", .{});
                return null;
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
        const buffers_bytes_size: usize = @as(usize, message_size) * @as(usize, queue_size);
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
            .init_flag = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size + buffers_bytes_size),
        };
    }

    pub fn getSharedMemoryPointer(self: *Self) [*]align(8) u8 {
        return @ptrCast(self.queue);
    }

    pub fn dumpHex(self: *Self) void {
        const mem_pointer = self.getSharedMemoryPointer();
        log.debug("dump hex from receiver. Pointer: {*}, shared mem size: {}", .{ mem_pointer, self.sharedMemorySize() });
        std.debug.dumpHex(mem_pointer[0..self.sharedMemorySize()]);
    }

    pub fn sharedMemorySize(self: *Self) usize {
        return getSharedMemorySize(self.params.queue_size, self.params.message_size);
    }

    pub fn dumpQueueHex(self: *Self) void {
        const QueueType = queue.Queue;
        std.debug.lockStdErr();
        log.debug("dump queue hex ({}) from receiver", .{@sizeOf(QueueType)});
        std.debug.unlockStdErr();
        const mem_pointer = self.getSharedMemoryPointer();
        std.debug.dumpHex(mem_pointer[0..@sizeOf(QueueType)]);
    }
};

pub fn getSharedMemorySize(queue_size: QueueLengthType, message_size: u32) usize {
    // // pub const shared_memory_size = @sizeOf(queue.Queue) + queue_size_param * @sizeOf(queue.ValueType) + message_size_param * queue_size_param + @sizeOf(i32);
    const shared_memory_size = @sizeOf(queue.Queue) + queueByteSize(queue_size) + @as(usize, queue_size) * @as(usize, message_size) + @sizeOf(i32);
    return shared_memory_size;
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

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;
    const socket_name = "/well-known-server-name";
    const shm_fd = os.shm_open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_memory_size = getSharedMemorySize(queue_size, message_size);
    log.debug("will mmap", .{});
    const shared_mem_pointer = switch (builtin.os.tag) {
        .linux => std.os.linux.mmap(
            null_addr,
            shared_memory_size,
            .{ .READ = true, .WRITE = true },
            .{
                .TYPE = .SHARED,
            },
            fd,
            0,
        ),
        .macos => std.c.mmap(
            null_addr,
            shared_memory_size,
            .{ .READ = true, .WRITE = true },
            .{
                .TYPE = .SHARED,
            },
            fd,
            0,
        ),
        else => @panic("unsupported OS"),
    };
    const shared_memory: [*]align(8) u8 = @ptrFromInt(shared_mem_pointer);
    var ipc_client = initClient(
        socket_name,
        @ptrCast(@alignCast(shared_memory[0..shared_memory_size].ptr)),
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
    var gpa = std.heap.DebugAllocator(.{}){};
    var allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;

    const socket_name = "/well-known-server-name";
    const shared_memory_size = getSharedMemorySize(queue_size, message_size);
    const shm_fd = os.shm_open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    // Open or create the shared memory object
    std.debug.assert(shm_fd != -1);
    const fd: std.posix.fd_t = @intCast(shm_fd);
    os.ftruncate(shm_fd, shared_memory_size);

    const shared_mem_slice = os.mmap(
        fd,
        shared_memory_size,
        .{ .READ = true, .WRITE = true },
        0,
    );
    const shared_memory: [*]align(8) u8 = @alignCast(shared_mem_slice.ptr);
    shared_memory[0] = 0;
    var server_sender = initServerSenderWithBuffer(
        socket_name,
        @ptrCast(@alignCast(shared_memory[0..shared_memory_size].ptr)),
        queue_size,
        message_size,
        0, // server_id
    );
    const some_data = try allocator.alloc(u8, 20);
    some_data[0] = 1;
    some_data[1] = 2;
    some_data[2] = 3;
    const thread_id = std.Thread.getCurrentId();
    log.debug("server running in thread {}", .{thread_id});
    try std.testing.expect(server_sender.send(some_data));

    var thread = try std.Thread.spawn(.{}, run_client, .{});
    thread.join();

    // const socket_fd = std.os.linux.socket(std.os.linux.AF.UNIX, std.os.linux.SOCK.DGRAM, 0);
    // defer _ = std.os.linux.close(@intCast(socket_fd));
    // const addr, const addr_len = sockAddrFromName(socket_name);
    // const bind_result = std.os.linux.bind(@intCast(socket_fd), @ptrCast(&addr), @truncate(addr_len));
    // std.debug.assert(bind_result == 0);
    // const connect_result = std.os.linux.connect(@intCast(socket_fd), @ptrCast(&addr), @truncate(addr_len));
    // std.debug.assert(connect_result == 0);

    // const client_connect_request = ipc_client.connect();
    // const client_connect_json = try std.json.stringifyAlloc(allocator, client_connect_request, .{
    //     .whitespace = .minified,
    // });
    // log.debug("connect request: {s}", .{client_connect_json});
}

fn queueByteSize(length: queue.LengthType) usize {
    return @intCast(@sizeOf(queue.Queue) + length * @sizeOf(queue.ValueType));
}
