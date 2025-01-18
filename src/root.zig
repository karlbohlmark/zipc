const std = @import("std");
const mod = @import("./zipc.zig");
const Zipc = mod.Zipc;
const Zipc_c = @import("./zipc_c.zig").Zipc_c;
const constants = @import("./constants.zig");

// const zipc_h = @cImport({
//     @cInclude("zipc.h");
// });

// comptime {
//     std.debug.assert(@sizeOf(zipc_h.ZipcContext) == @sizeOf(Zipc_c(1536, 64).ZipcContext));
// }

const build_options = @import("build_options");

const Zipc_1536_64 = Zipc(build_options.message_size, build_options.queue_size);
// const Zipc_1536_64 = Zipc(8, 4);
export fn zipc_1536_64_create_receiver(name: [*:0]const u8) Zipc_1536_64.ZipcClientReceiver {
    const zipc_c = Zipc_c(
        Zipc_1536_64.message_size,
        Zipc_1536_64.queue_size,
    );
    return zipc_c.zipc_create_receiver(name);
}
export fn zipc_1536_64_create_sender(name: [*:0]const u8) Zipc_1536_64.ZipcServerSender {
    const zipc_c = Zipc_c(
        Zipc_1536_64.message_size,
        Zipc_1536_64.queue_size,
    );
    return zipc_c.zipc_create_sender(name);
}
export fn zipc_unlink(name: [*:0]const u8) void {
    const path = zipc_shm_path(name);
    const result = std.os.linux.unlink(path);
    _ = result;
}
export fn zipc_1536_64_receiver_wait_for_initialization(receiver: *Zipc_1536_64.ZipcClientReceiver) usize {
    const futex_wait_return = std.os.linux.futex_wait(
        receiver.init_flag,
        std.os.linux.FUTEX.WAIT,
        @intCast(0),
        null,
    );
    return futex_wait_return;
}
export fn zipc_1536_64_send(sender: *Zipc_1536_64.ZipcServerSender, message: [*]const u8, message_size: usize) void {
    const message_slice: []const u8 = message[0..message_size];
    sender.send(message_slice);
}
export fn zipc_1536_64_receive(receiver: *Zipc_1536_64.ZipcClientReceiver, message: *[*]allowzero const u8) usize {
    if (receiver.receive()) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return message_slice.len;
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}
export fn zipc_1536_64_receive_blocking(receiver: *Zipc_1536_64.ZipcClientReceiver, message: *[*]allowzero const u8, timeout_ms: u16) usize {
    if (receiver.receive_blocking(timeout_ms)) |item| {
        _, const message_slice = item;
        message.* = message_slice.ptr;
        return message_slice.len;
    } else {
        message.* = @ptrFromInt(0);
        return 0;
    }
}

const Zipc_1536_256 = Zipc(1536, 256);
export fn zipc_1536_256_create_receiver(name: [*:0]const u8) Zipc_1536_256.ZipcClientReceiver {
    const zipc_c = Zipc_c(
        Zipc_1536_256.message_size,
        Zipc_1536_256.queue_size,
    );
    return zipc_c.zipc_create_receiver(name);
}
export fn zipc_1536_256_create_sender(name: [*:0]const u8) Zipc_1536_256.ZipcServerSender {
    const zipc_c = Zipc_c(
        Zipc_1536_256.message_size,
        Zipc_1536_256.queue_size,
    );
    return zipc_c.zipc_create_sender(name);
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
    const full_path = std.mem.concat(std.heap.page_allocator, u8, &[_][]const u8{ "/dev/shm", std.mem.span(name), "\x00"[0..1] }) catch |err| {
        std.debug.print("failed to concat path: {}\n", .{err});
        std.process.exit(1);
    };
    return @ptrCast(full_path.ptr);
}
