const std = @import("std");
const Zipc = @import("./zipc.zig");
const Zipc_c = @import("./zipc_c.zig");
const constants = @import("./constants.zig");
const os = @import("./os.zig");

export fn zipc_create_receiver(name: [*:0]const u8, message_size: u32, queue_size: u32) Zipc.ZipcClientReceiver {
    return Zipc_c.zipc_create_receiver(name, message_size, queue_size);
}
export fn zipc_create_sender(name: [*:0]const u8, message_size: u32, queue_size: u32) Zipc.ZipcServerSender {
    return Zipc_c.zipc_create_sender(name, message_size, queue_size);
}
export fn zipc_unlink(name: [*:0]const u8) void {
    const path = zipc_shm_path(name);
    const result = os.unlink(path);
    _ = result;
}
export fn zipc_send(sender: *Zipc.ZipcServerSender, message: [*]const u8, message_size: usize) void {
    const message_slice: []const u8 = message[0..message_size];
    sender.send(message_slice);
}
export fn zipc_receive(receiver: *Zipc.ZipcClientReceiver, message: *[*]allowzero const u8) usize {
    if (receiver.receive()) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return message_slice.len;
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}
export fn zipc_receive_blocking(receiver: *Zipc.ZipcClientReceiver, message: *[*]allowzero const u8, timeout_ms: u16) usize {
    if (receiver.receive_blocking(timeout_ms)) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return message_slice.len;
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}

export fn zipc_shm_path(name: [*:0]const u8) [*:0]const u8 {
    if (std.mem.len(name) == 0) {
        std.debug.print("Shared memory name must be more than 0 characters\n", .{});
        std.debug.assert(std.mem.len(name) > 0);
    }
    if (name[0] != '/') {
        std.debug.print("Shared memory name must start with a '/'\n", .{});
        std.debug.assert(name[0] == '/');
    }

    const full_path = std.fs.path.joinZ(std.heap.page_allocator, &.{ "/dev/shm", std.mem.span(name) }) catch |err| {
        std.debug.print("failed to concat path: {}\n", .{err});
        std.process.exit(1);
    };
    return full_path;
}
