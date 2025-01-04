const std = @import("std");

const handshake = @import("./handshake.zig");
const queue = @import("./queue.zig");
const shm = @import("./shm.zig");
const constants = @import("./constants.zig");
const send_fd = handshake.send_fd;
const receive_fd = handshake.receive_fd;

const FD = std.os.linux.fd_t;

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

pub fn Zipc(message_size_param: comptime_int, queue_size_param: comptime_int) type {
    return struct {
        const Queue = queue.LamportQueueU64(queue_size_param);
        pub const shared_memory_size = @sizeOf(queue.LamportQueueU64(queue_size_param)) + message_size_param * queue_size_param + @sizeOf(@typeInfo(@FieldType(ZipcServerSender, "init_flag")).pointer.child);
        pub const message_size: u16 = message_size_param;
        pub const queue_size: u16 = queue_size_param;

        pub const ZipcParams = packed struct {
            message_size: u16 = message_size_param,
            queue_size: u16 = queue_size_param,
        };

        const ZipcServer = struct {
            name: []const u8,

            abstract_domain_socket: std.os.linux.fd_t,
        };

        pub const ZipcServerSender = extern struct {
            const Self = @This();
            server_id: u64,
            name: [*:0]const u8,
            params: ZipcParams = .{
                .message_size = message_size_param,
                .queue_size = queue_size_param,
            },
            queue: *queue.LamportQueueU64(queue_size_param),
            buffers: *[queue_size_param][message_size_param]u8,
            init_flag: *i32,

            pub fn send(self: *Self, message: []const u8) void {
                std.debug.print("zig side sending message of len {}: #{s}#\n", .{ message.len, message });
                self.dumpHex();
                const next_index = self.queue.tail;
                std.mem.copyForwards(u8, self.buffers[next_index][0..message.len], message);
                _ = self.queue.enqueue(message.len);
            }

            pub fn init(name: [*:0]const u8, shared_mem_ptr: *align(8) [shared_memory_size]u8, server_id: u64) ZipcServerSender {
                std.debug.lockStdErr();
                std.debug.print("dump hex from sender {*}\n", .{shared_mem_ptr});
                std.debug.dumpHex(shared_mem_ptr[0..shared_memory_size]);
                std.debug.unlockStdErr();
                const queue_byte_size: usize = @intCast(@sizeOf(queue.LamportQueueU64(queue_size_param)));
                const buffers_bytes_size: usize = @intCast(message_size_param * queue_size_param);
                const init_flag_ptr_int: usize = @intFromPtr(shared_mem_ptr) + queue_byte_size + buffers_bytes_size;
                const init_flag_ptr: *i32 = @ptrFromInt(init_flag_ptr_int);
                std.debug.print("init_flag value before init: {}\n", .{init_flag_ptr.*});
                var q: *Queue = @ptrCast(@alignCast(shared_mem_ptr));
                if (init_flag_ptr.* != constants.ZIPC_MAGIC) {
                    q.init();
                    @atomicStore(i32, init_flag_ptr, constants.ZIPC_MAGIC, .release);
                }
                // std.debug.print("will wake", .{});
                _ = std.os.linux.futex_wake(init_flag_ptr, std.os.linux.FUTEX.WAKE, 1);
                std.debug.print("init_flag value after init: {}\n", .{init_flag_ptr.*});
                return .{
                    .server_id = server_id,
                    .name = name,
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
                std.debug.print("dump hex from sender {*}\n", .{mem_pointer});
                std.debug.dumpHex(mem_pointer[0..shared_memory_size]);
            }

            pub fn dumpQueueHex(self: *Self) void {
                const QueueType = queue.LamportQueueU64(queue_size_param);
                std.debug.print("dump queue hex ({}) from sender\n", .{@sizeOf(QueueType)});
                const mem_pointer = self.getSharedMemoryPointer();
                std.debug.dumpHex(mem_pointer[0..@sizeOf(QueueType)]);
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
            name: [*:0]const u8,
            params: ZipcParams = .{
                .message_size = message_size_param,
                .queue_size = queue_size_param,
            },
            queue: *queue.LamportQueueU64(queue_size_param),
            buffers: *[queue_size_param][message_size_param]u8,
            init_flag: *i32,

            pub fn connect(self: *Self) ZipcClientConnectRequest {
                return .{
                    .method = ZipcControlMethod.Connect,
                    .params = self.params,
                };
            }

            pub fn receive(self: *Self) struct { u32, []u8 } {
                std.debug.lockStdErr();
                std.debug.print("receive dump hex\n", .{});
                self.dumpHex();
                std.debug.unlockStdErr();
                const index, const val = self.queue.dequeue();
                if (index > (1 << 16)) {
                    return .{ 1 << 17, &[_]u8{} };
                } else {
                    return .{ index, self.buffers[index][0..val] };
                }
            }

            pub fn init(name: [*:0]const u8, shared_mem_ptr: *align(8) [shared_memory_size]u8, client_id: u64) ZipcClientReceiver {
                const queue_byte_size: usize = @intCast(@sizeOf(queue.LamportQueueU64(queue_size_param)));
                const buffers_bytes_size: usize = @intCast(message_size_param * queue_size_param);
                return .{
                    .client_id = client_id,
                    .name = name,
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
                std.debug.print("dump hex from receiver. Pointer: {*}, shared mem size: {}\n", .{ mem_pointer, shared_memory_size });
                std.debug.dumpHex(mem_pointer[0..shared_memory_size]);
            }

            pub fn dumpQueueHex(self: *Self) void {
                const QueueType = queue.LamportQueueU64(queue_size_param);
                std.debug.lockStdErr();
                std.debug.print("dump queue hex ({}) from receiver\n", .{@sizeOf(QueueType)});
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
    std.debug.print("client running in thread {}", .{thread_id});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;
    const ZipcInstance = Zipc(message_size, queue_size);
    const socket_name = "/well-known-server-name";
    const shm_fd = shm.open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_memory_size: comptime_int = ZipcInstance.shared_memory_size;
    const shared_mem_pointer = std.os.linux.mmap(
        null_addr,
        shared_memory_size,
        std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
        .{
            .TYPE = .SHARED,
        },
        fd,
        0,
    );
    const shared_memory: *align(8) [shared_memory_size]u8 = @ptrFromInt(shared_mem_pointer);
    var ipc_client = ZipcInstance.initClient(
        socket_name,
        @ptrCast(@alignCast(shared_memory[0..shared_memory_size].ptr)),
    );
    const index, const message_slice = ipc_client.receive();
    std.debug.print("received index {} and slice with length {}: {X}", .{ index, message_slice.len, message_slice });
}

test "client server connection test" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const message_size = 1536;
    const queue_size = 128;
    const ZipcInstance = Zipc(message_size, queue_size);
    const socket_name = "/well-known-server-name";
    const shared_memory_size: comptime_int = ZipcInstance.shared_memory_size;
    const shm_fd = shm.open(allocator, socket_name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    // Open or create the shared memory object
    std.debug.assert(shm_fd != -1);
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const ftruncate_result = std.os.linux.ftruncate(shm_fd, shared_memory_size);
    std.debug.assert(ftruncate_result == 0);
    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_mem_pointer = std.os.linux.mmap(
        null_addr,
        shared_memory_size,
        std.os.linux.PROT.READ | std.os.linux.PROT.WRITE,
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
    std.debug.print("server running in thread {}", .{thread_id});
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
    // std.debug.print("connect request: {s}\n", .{client_connect_json});
}
