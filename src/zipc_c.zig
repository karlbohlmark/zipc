const std = @import("std");
const shm = @import("./shm.zig");
const Zipc = @import("./zipc.zig").Zipc;
const unix_mod = @import("./unix.zig");
const bindUnixSocket = unix_mod.bindUnixSocket;
pub fn Zipc_c(message_size: comptime_int, queue_size: comptime_int) type {
    const ZipcInstance = Zipc(message_size, queue_size);
    const allocator = std.heap.page_allocator;
    return struct {
        pub fn zipc_create_receiver(name: [*:0]const u8) Zipc(message_size, queue_size).ZipcClientReceiver {
            std.debug.print("zipc_create_receiver {} {}\n", .{ message_size, queue_size });
            const name_slice = std.mem.span(name);
            const shm_fd = shm.open(allocator, name_slice, .{
                .CREAT = true,
                .ACCMODE = .RDWR,
            }, 0o600);
            const fd: std.os.linux.fd_t = @intCast(shm_fd);
            std.debug.print("shm_fd in receiver {}\n", .{shm_fd});
            const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
            const shared_memory_size: comptime_int = ZipcInstance.shared_memory_size;
            const ftruncate_result = std.os.linux.ftruncate(shm_fd, shared_memory_size);
            std.debug.print("did ftruncate\n", .{});
            std.debug.assert(ftruncate_result == 0);
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
            std.debug.print("receiver did mmap, pointer: {*}\n", .{shared_memory});
            // std.debug.lockStdErr();
            // std.debug.print("share mem pointer receiver {*}", .{shared_memory});
            // std.debug.print("dump hex from receiver {}\n", .{shared_memory_size});
            // std.debug.dumpHex(shared_memory[0..shared_memory_size]);
            // std.debug.unlockStdErr();

            var ts: std.posix.timespec = undefined;
            std.posix.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) catch |err| {
                std.debug.print("clock_gettime failed: {}\n", .{err});
                std.process.exit(1);
            };
            const client_id: u64 = getIdentifyFromPidAndTime(std.os.linux.getpid(), ts);
            return ZipcInstance.initClient(name_slice, shared_memory, client_id);
        }
        pub fn zipc_create_sender(name: [*:0]const u8) Zipc(message_size, queue_size).ZipcServerSender {
            std.debug.print("zipc_create_sender {} {}\n", .{ message_size, queue_size });
            const name_slice = std.mem.span(name);
            // shm.unlink(allocator, name_slice);
            const shm_fd = shm.open(allocator, name_slice, .{
                .CREAT = true,
                .ACCMODE = .RDWR,
            }, 0o600);
            std.debug.print("shm_fd in sender {}\n", .{shm_fd});
            const fd: std.os.linux.fd_t = @intCast(shm_fd);
            const ftruncate_result = std.os.linux.ftruncate(shm_fd, ZipcInstance.shared_memory_size);
            std.debug.assert(ftruncate_result == 0);
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
            std.debug.print("sender did mmap, pointer: {*}\n", .{shared_memory});

            var ts: std.posix.timespec = undefined;
            std.posix.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) catch |err| {
                std.debug.print("clock_gettime failed: {}\n", .{err});
                std.process.exit(1);
            };
            const pid = std.os.linux.getpid();
            const server_id: u64 = getIdentifyFromPidAndTime(pid, ts);
            const control_socket_fd = bindUnixSocket(name_slice);
            _ = control_socket_fd;
            return ZipcInstance.initServerSenderWithBuffer(name_slice, shared_memory, server_id);
        }
    };
}

pub fn getIdentifyFromPidAndTime(pid: i32, ts: std.posix.timespec) u64 {
    return @as(u64, @intCast((ts.sec & 0xFFFFFFFF) << 16)) | @as(u64, @intCast(pid));
}
