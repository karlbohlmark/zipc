const std = @import("std");
const os = @import("./os.zig");
const Zipc = @import("./zipc.zig");
const unix_mod = @import("./unix.zig");
const bindUnixSocket = unix_mod.bindUnixSocket;

const log = std.log.scoped(.zipc_c);
const allocator = std.heap.page_allocator;

pub fn zipc_create_receiver(name: [*:0]const u8, queue_size: u32, message_size: u32) Zipc.ZipcClientReceiver {
    log.debug("zipc_create_receiver {} {}", .{ message_size, queue_size });
    const name_slice = std.mem.span(name);
    const shm_fd = os.shm_open(allocator, name_slice, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const null_addr: ?[*]u8 = null; // Hint to the kernel: no specific address
    const shared_memory_size: usize = Zipc.getSharedMemorySize(queue_size, message_size);
    os.ftruncate(shm_fd, shared_memory_size);
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
    const shared_memory: [*]align(8) u8 = @ptrFromInt(shared_mem_pointer);
    log.debug("receiver did mmap, pointer: {*}", .{shared_memory});
    // std.debug.lockStdErr();
    // log.debug("share mem pointer receiver {*}", .{shared_memory});
    // log.debug("dump hex from receiver {}", .{shared_memory_size});
    // std.debug.dumpHex(shared_memory[0..shared_memory_size]);
    // std.debug.unlockStdErr();

    const ts: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch |err| {
        log.debug("clock_gettime failed: {}", .{err});
        std.process.exit(1);
    };
    const client_id: u64 = getIdentifyFromPidAndTime(std.os.linux.getpid(), ts);
    return Zipc.initClient(name_slice, shared_memory, queue_size, message_size, client_id);
}
pub fn zipc_create_sender(name: [*:0]const u8, queue_size: u32, message_size: u32) Zipc.ZipcServerSender {
    log.debug("zipc_create_sender {} {}", .{ message_size, queue_size });
    const name_slice = std.mem.span(name);
    // shm.unlink(allocator, name_slice);
    const shm_fd = os.shm_open(allocator, name_slice, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    }, 0o600);
    log.debug("shm_fd in sender {}", .{shm_fd});
    const fd: std.os.linux.fd_t = @intCast(shm_fd);
    const shared_memory_size: usize = Zipc.getSharedMemorySize(queue_size, message_size);
    log.debug("will truncate to length {}", .{shared_memory_size});
    os.ftruncate(shm_fd, @intCast(shared_memory_size));
    log.debug("after truncate", .{});
    // const ftruncate_result = std.os.linux.ftruncate(shm_fd, shared_memory_size);
    // log.debug("ftruncate result {}", .{});
    // std.debug.assert(ftruncate_result == 0);
    const shared_memory: [*]align(8) u8 = @alignCast(@ptrCast(os.mmap(
        fd,
        shared_memory_size,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        0,
    )));

    log.debug("sender did mmap, pointer: {*}", .{shared_memory});

    const ts: std.posix.timespec = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch |err| {
        log.debug("clock_gettime failed: {}", .{err});
        std.process.exit(1);
    };
    const pid = os.getpid();
    const server_id: u64 = getIdentifyFromPidAndTime(pid, ts);
    // const control_socket_fd = bindUnixSocket(name_slice);
    // _ = control_socket_fd;
    return Zipc.initServerSenderWithBuffer(name_slice, shared_memory, queue_size, message_size, server_id);
}

pub fn getIdentifyFromPidAndTime(pid: i32, ts: std.posix.timespec) u64 {
    return @as(u64, @intCast((ts.sec & 0xFFFFFFFF) << 16)) | @as(u64, @intCast(pid));
}
