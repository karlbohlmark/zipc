const std = @import("std");
const os = @import("./os.zig");
const Zipc_c = @import("./zipc_c.zig");
const queue_size = 8;
const message_size = 1536;
const zipc_path = "/my-zipc-path";

pub fn main() !void {
    var sender = Zipc_c.zipc_create_sender(zipc_path, queue_size, message_size);

    while (true) {
        std.debug.print("will send\n", .{});
        const message = "hello!";
        sender.send(message);
        _ = os.nanosleep(0, 200_000_000);
    }
}
