const std = @import("std");
const os = @import("./os.zig");
const Zipc_c = @import("./zipc_c.zig");
const zipc_c = Zipc_c(1536, 64);
const queue_size = 8;
const message_size = 4;
// const zipc_c = Zipc_c(8, 4);

pub fn main() !void {
    var sender = Zipc_c.zipc_create_sender("/6", queue_size, message_size);

    while (true) {
        std.debug.print("will send\n", .{});
        const message = "hello!";
        sender.send(message);
        _ = os.nanosleep(0, 200_000_000);
    }
}
