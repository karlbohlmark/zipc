const std = @import("std");
const Zipc = @import("./zipc.zig");
const Zipc_c = @import("./zipc_c.zig");
const constants = @import("./constants.zig");
const os = @import("./os.zig");

const log = std.log.scoped(.zipc);

/// On failure, logs the reason and returns a context whose pointers are all
/// null. C callers detect this via `context.queue == NULL`; every zipc call
/// on such a context is a safe no-op.
export fn zipc_create_receiver(name: [*:0]const u8, queue_size: u32, message_size: u32) Zipc.ZipcClientReceiver {
    return Zipc_c.zipc_create_receiver(name, queue_size, message_size) catch |err| {
        log.err("zipc_create_receiver(\"{s}\", queue_size={}, message_size={}) failed: {s}", .{ name, queue_size, message_size, @errorName(err) });
        return Zipc.invalidClientReceiver();
    };
}

export fn zipc_create_sender(name: [*:0]const u8, queue_size: u32, message_size: u32) Zipc.ZipcServerSender {
    return Zipc_c.zipc_create_sender(name, queue_size, message_size) catch |err| {
        log.err("zipc_create_sender(\"{s}\", queue_size={}, message_size={}) failed: {s}", .{ name, queue_size, message_size, @errorName(err) });
        return Zipc.invalidServerSender();
    };
}

/// Unmaps the channel's shared memory and invalidates the context. The
/// segment itself stays in the filesystem until zipc_unlink(). Works for
/// sender and receiver contexts alike (identical layout); safe to call on an
/// already-destroyed or failed context.
export fn zipc_destroy(context: *Zipc.ZipcServerSender) void {
    const q = context.queue orelse return;
    const size = Zipc.getSharedMemorySize(context.params.queue_size, context.params.message_size);
    os.munmap(@ptrCast(@alignCast(q)), size);
    context.queue = null;
    context.buffers = null;
    context.init_flag = null;
}

export fn zipc_unlink(name: [*:0]const u8) void {
    os.shmUnlink(std.mem.span(name)) catch |err| {
        log.err("zipc_unlink(\"{s}\") failed: {s}", .{ name, @errorName(err) });
    };
}

export fn zipc_send(sender: *Zipc.ZipcServerSender, message: [*]const u8, message_size: usize) bool {
    const message_slice: []const u8 = message[0..message_size];
    return sender.send(message_slice);
}

export fn zipc_receive(receiver: *Zipc.ZipcClientReceiver, message: *[*]allowzero const u8) u32 {
    if (receiver.receive()) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return @intCast(message_slice.len);
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}

export fn zipc_receive_blocking(receiver: *Zipc.ZipcClientReceiver, message: *[*]allowzero const u8, timeout_ms: u16) u32 {
    if (receiver.receive_blocking(timeout_ms)) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return @intCast(message_slice.len);
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}

/// Static buffer: the returned pointer is valid until the next call from any
/// thread. Returns an empty string for an invalid name.
var shm_path_buffer: os.PathBuffer = undefined;
export fn zipc_shm_path(name: [*:0]const u8) [*:0]const u8 {
    return os.shmPath(&shm_path_buffer, std.mem.span(name)) catch |err| {
        log.err("zipc_shm_path(\"{s}\") failed: {s}", .{ name, @errorName(err) });
        // Error path also points into the static buffer, keeping the
        // documented "static buffer, don't free" contract on both paths.
        shm_path_buffer[0] = 0;
        return @ptrCast(&shm_path_buffer);
    };
}

test {
    _ = @import("./zipc.zig");
    _ = @import("./queue.zig");
}
