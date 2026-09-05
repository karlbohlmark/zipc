const std = @import("std");
const os = @import("./os.zig");
const Zipc = @import("./zipc.zig");

const log = std.log.scoped(.zipc_c);

pub const CreateError = os.Error || error{
    InvalidQueueSize,
    InvalidMessageSize,
    InvalidSize,
};

/// Opens (creating if needed) and maps the shared memory segment for a
/// channel. The shm fd is closed before returning: the mapping keeps the
/// segment alive, and zipc_destroy() only needs to munmap.
fn openAndMapChannel(name: []const u8, queue_size: u32, message_size: u32) CreateError![*]align(8) u8 {
    // The ring keeps one slot unused, so queue_size 0 and 1 cannot hold any
    // message (and 0 would divide by zero in the index math).
    if (queue_size < 2) return CreateError.InvalidQueueSize;
    if (message_size == 0) return CreateError.InvalidMessageSize;

    const fd = try os.shm_open(name, .{
        .CREAT = true,
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0o600);
    defer os.close(fd);

    const shared_memory_size: usize = Zipc.checkedSharedMemorySize(queue_size, message_size) orelse
        return CreateError.InvalidSize;
    try os.ftruncate(fd, shared_memory_size);
    try os.preallocate(fd, shared_memory_size);
    const shared_memory = try os.mmap(fd, shared_memory_size, 0);
    return shared_memory.ptr;
}

pub fn zipc_create_sender(name: [*:0]const u8, queue_size: u32, message_size: u32) CreateError!Zipc.ZipcServerSender {
    log.debug("zipc_create_sender queue_size={} message_size={}", .{ queue_size, message_size });
    const shared_memory = try openAndMapChannel(std.mem.span(name), queue_size, message_size);
    return Zipc.initServerSenderWithBuffer(name, shared_memory, queue_size, message_size, makeId());
}

pub fn zipc_create_receiver(name: [*:0]const u8, queue_size: u32, message_size: u32) CreateError!Zipc.ZipcClientReceiver {
    log.debug("zipc_create_receiver queue_size={} message_size={}", .{ queue_size, message_size });
    const shared_memory = try openAndMapChannel(std.mem.span(name), queue_size, message_size);
    return Zipc.initClient(name, shared_memory, queue_size, message_size, makeId());
}

fn makeId() u64 {
    const seconds: u64 = os.monotonicNanos() / std.time.ns_per_s;
    return getIdentifyFromPidAndTime(os.getpid(), seconds);
}

pub fn getIdentifyFromPidAndTime(pid: i32, seconds: u64) u64 {
    return ((seconds & 0xFFFFFFFF) << 16) | @as(u64, @intCast(pid));
}
