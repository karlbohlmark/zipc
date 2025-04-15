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

pub fn Zipc(message_size_param: comptime_int, queue_size_param: comptime_int) type {
    return struct {
        const Queue = queue.Queue;
        pub const shared_memory_size = @sizeOf(queue.Queue) + queue_size_param * @sizeOf(queue.ValueType) + message_size_param * queue_size_param + @sizeOf(i32);
        pub const message_size: u32 = message_size_param;
        pub const queue_size: QueueLengthType = queue_size_param;

        pub const ZipcParams = packed struct {
            message_size: u32 = message_size_param,
            queue_size: QueueLengthType = queue_size_param,
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
            params: ZipcParams = .{
                .message_size = message_size_param,
                .queue_size = queue_size_param,
            },
            queue: *queue.Queue,
            buffers: *[queue_size_param][message_size_param]u8,
            init_flag: *i32,

            pub fn send(self: *Self, message: []const u8) void {
                const next_index = self.queue.tail;
                std.mem.copyForwards(u8, self.buffers[next_index][0..message.len], message);
                _ = self.queue.enqueue(queue_size_param, message.len);

                if (builtin.target.os.tag == .linux) {
                    const wake_return_val = std.os.linux.futex_wake(@ptrCast(&self.queue.tail), std.os.linux.FUTEX.WAKE, 1);
                    log.debug("wake_return_val: {}", .{wake_return_val});
                }
            }

            pub fn init(name: [*:0]const u8, shared_mem_ptr: *align(8) [shared_memory_size]u8, server_id: u64) ZipcServerSender {
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
                const queue_byte_size: usize = queueByteSize(queue_size_param);
                const buffers_bytes_size: usize = @intCast(message_size_param * queue_size_param);
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
                        .message_size = message_size_param,
                        .queue_size = queue_size_param,
                    },
                    .queue = q,
                    .buffers = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size),
                    .init_flag = init_flag_ptr,
                };
            }

            pub fn dumpHex(self: *Self) void {
                const mem_pointer = self.getSharedMemoryPointer();
                log.debug("dump hex from sender");
                std.debug.dumpHex(mem_pointer[0..shared_memory_size]);
            }

            pub fn dumpQueueHex(self: *Self) void {
                const queue_size_bytes = @sizeOf(queue.Queue) + queue_size_param * @sizeOf(queue.ValueType);
                log.debug("dump queue hex ({}) from sender", .{queue_size_bytes});
                const mem_pointer = self.getSharedMemoryPointer();
                std.debug.dumpHex(mem_pointer[0..queue_size_bytes]);
            }

            pub fn getSharedMemoryPointer(self: *Self) *align(8) [shared_memory_size]u8 {
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
            params: ZipcParams = .{
                .message_size = message_size_param,
                .queue_size = queue_size_param,
            },
            queue: *queue.Queue,
            buffers: *[queue_size_param][message_size_param]u8,
            init_flag: *i32,

            pub fn connect(self: *Self) ZipcClientConnectRequest {
                return .{
                    .method = ZipcControlMethod.Connect,
                    .params = self.params,
                };
            }

            pub fn receive(self: *Self) ?struct { QueueLengthType, []u8 } {
                var current_tail: QueueLengthType = 0;
                if (self.queue.dequeue(queue_size_param, &current_tail)) |item| {
                    const index, const val = item;
                    log.debug("received val {}", .{val});
                    return .{ index, self.buffers[index][0..val] };
                } else {
                    return null;
                }
            }

            pub fn receive_blocking(self: *Self, timeout_ms: u16) ?struct { QueueLengthType, []u8 } {
                // self.dumpHex();
                if (timeout_ms >= 1000) {
                    @panic("timeout_ms must be less than 1000");
                }
                var current_tail: QueueLengthType = 0;
                if (self.queue.dequeue(queue_size_param, &current_tail)) |item| {
                    const index, const val = item;
                    return .{ index, self.buffers[index][0..val] };
                } else {
                    log.debug("queue empty, waiting", .{});
                    const timestamp_ms = std.time.milliTimestamp();
                    const timeout_timespec = std.posix.timespec{
                        .sec = 0,
                        .nsec = @intCast((@as(u32, @intCast(timeout_ms)) % 1000) * 1_000_000),
                    };
                    if (builtin.target.os.tag == .linux) {
                        const futex_return_value = std.os.linux.futex_wait(@ptrCast(&self.queue.tail), std.os.linux.FUTEX.WAIT, @intCast(current_tail), &timeout_timespec);
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
                    const elapsed_ms: i64 = std.time.milliTimestamp() - @as(i64, @intCast(timestamp_ms));
                    if (elapsed_ms < timeout_ms) {
                        const remaining_ms: i64 = @as(i64, @intCast(timeout_ms)) - elapsed_ms;
                        return self.receive_blocking(@truncate(@abs(remaining_ms)));
                    } else {
                        log.debug("receive_blocking timed out", .{});
                        return null;
                    }
                }
            }

            pub fn init(name: [*:0]const u8, shared_mem_ptr: *align(8) [shared_memory_size]u8, client_id: u64) ZipcClientReceiver {
                const name_slice = std.mem.span(name);
                if (name_slice.len >= 40) {
                    @panic("name length cannot be longer than 39");
                }
                var dest_name: ZipcName = undefined;
                std.mem.copyForwards(u8, dest_name[0..name_slice.len], name_slice);
                dest_name[name_slice.len] = 0;
                const queue_byte_size: usize = queueByteSize(queue_size_param);
                const buffers_bytes_size: usize = @intCast(message_size_param * queue_size_param);
                return .{
                    .client_id = client_id,
                    .connection_mode = ZipcConnectionMode.Client,
                    .name = dest_name,
                    .params = .{
                        .message_size = message_size_param,
                        .queue_size = queue_size_param,
                    },
                    .queue = @ptrCast(@alignCast(shared_mem_ptr)),
                    .buffers = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size),
                    .init_flag = @ptrFromInt(@intFromPtr(shared_mem_ptr) + queue_byte_size + buffers_bytes_size),
                };
            }

            pub fn getSharedMemoryPointer(self: *Self) *align(8) [shared_memory_size]u8 {
                return @ptrCast(self.queue);
            }

            pub fn dumpHex(self: *Self) void {
                const mem_pointer = self.getSharedMemoryPointer();
                log.debug("dump hex from receiver. Pointer: {*}, shared mem size: {}", .{ mem_pointer, shared_memory_size });
                std.debug.dumpHex(mem_pointer[0..shared_memory_size]);
            }

            pub fn dumpQueueHex(self: *Self) void {
                const QueueType = queue.LamportQueueU64(queue_size_param);
                std.debug.lockStdErr();
                log.debug("dump queue hex ({}) from receiver", .{@sizeOf(QueueType)});
                std.debug.unlockStdErr();
                const mem_pointer = self.getSharedMemoryPointer();
                std.debug.dumpHex(mem_pointer[0..@sizeOf(QueueType)]);
            }
        };

        pub fn initServerSenderWithBuffer(
            name: [*:0]const u8,
            shared_memory: *align(8) [shared_memory_size]u8,
            server_id: u64,
        ) ZipcServerSender {
            return ZipcServerSender.init(name, shared_memory, server_id);
        }

        pub fn initClient(
            name: [*:0]const u8,
            shared_memory: *align(8) [shared_memory_size]u8,
            client_id: u64,
        ) ZipcClientReceiver {
            return ZipcClientReceiver.init(name, shared_memory, client_id);
        }
    };
}

pub fn run_client() !void {
    const thread_id = std.Thread.getCurrentId();
    log.debug("client running in thread {}", .{thread_id});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;
    const ZipcInstance = Zipc(message_size, queue_size);
    const socket_name = "/well-known-server-name";
    const shm_fd = os.shm_open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_memory_size: comptime_int = ZipcInstance.shared_memory_size;
    log.debug("will mmap", .{});
    const shared_mem_pointer = switch (builtin.os.tag) {
        .linux => std.os.linux.mmap(
            null_addr,
            shared_memory_size,
            std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
            .{
                .TYPE = .SHARED,
            },
            fd,
            0,
        ),
        .macos => std.c.mmap(
            null_addr,
            shared_memory_size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{
                .TYPE = .SHARED,
            },
            fd,
            0,
        ),
        else => @panic("unsupported OS"),
    };
    const shared_memory: *align(8) [shared_memory_size]u8 = @ptrFromInt(shared_mem_pointer);
    var ipc_client = ZipcInstance.initClient(
        socket_name,
        @ptrCast(@alignCast(shared_memory[0..shared_memory_size].ptr)),
    );
    const index, const message_slice = ipc_client.receive();
    log.debug("received index {} and slice with length {}: {X}", .{ index, message_slice.len, message_slice });
}

test "client server connection test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;
    const ZipcInstance = Zipc(message_size, queue_size);
    const socket_name = "/well-known-server-name";
    const shared_memory_size: comptime_int = ZipcInstance.shared_memory_size;
    const shm_fd = os.shm_open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    // Open or create the shared memory object
    std.debug.assert(shm_fd != -1);
    const fd: std.posix.fd_t = @intCast(shm_fd);
    os.ftruncate(shm_fd, shared_memory_size);

    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_mem_pointer = os.mmap(
        null_addr,
        shared_memory_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{
            .TYPE = .SHARED,
        },
        fd,
        0,
    );
    // check if mmap was successful
    std.debug.assert(shared_mem_pointer != @intFromPtr(std.c.MAP_FAILED));
    const shared_memory: *align(8) [shared_memory_size]u8 = @ptrFromInt(shared_mem_pointer);
    shared_memory[0] = 0;
    var server_sender = ZipcInstance.initServerSenderWithBuffer(
        socket_name,
        @ptrCast(@alignCast(shared_memory[0..shared_memory_size].ptr)),
    );
    const some_data = try allocator.alloc(u8, 20);
    some_data[0] = 1;
    some_data[1] = 2;
    some_data[2] = 3;
    const thread_id = std.Thread.getCurrentId();
    log.debug("server running in thread {}", .{thread_id});
    server_sender.send(some_data);

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
