const std = @import("std");
const Zipc_c = @import("./zipc_c.zig");
const queue_size = 8;
const message_size = 4;
// const zipc_c = Zipc_c(8, 4);

pub fn main() !void {
    var receiver = Zipc_c.zipc_create_receiver("/my-zipc-path", queue_size, message_size);

    // To allow starting the receiver before the sender, we wait for a first message
    // to be received before starting the main loop.
    wait_for_first_message: while (true) {
        if (receiver.receive()) |first_item| {
            _, const message_slice = first_item;
            std.debug.print("received first message of len: {}\n", .{message_slice.len});
            break :wait_for_first_message;
        } else {
            std.debug.print("nothing received\n", .{});
            sleep(500);
        }
    }
    // First message has been received, we can start the main loop

    std.debug.print("will receive blocking\n", .{});
    while (receiver.receive_blocking(800)) |item| {
        _, const message_slice = item;
        const seq_no = std.mem.readInt(u16, message_slice[2..4], .big);
        std.debug.print("received message of len: {} with seq no: {}\n", .{ message_slice.len, seq_no });
    }
    std.debug.print("receive timed out\n", .{});
}

fn sleep(ms: u32) void {
    var rem: std.os.linux.timespec = undefined;
    const duration: std.os.linux.timespec = .{ .sec = 0, .nsec = ms * 1_000_000 };
    _ = std.os.linux.nanosleep(&duration, &rem);
}
