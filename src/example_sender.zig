const std = @import("std");
const os = @import("./os.zig");
const Zipc_c = @import("./zipc_c.zig").Zipc_c;
const zipc_c = Zipc_c(1536, 64);
// const zipc_c = Zipc_c(8, 4);

pub fn main() !void {
    var sender = zipc_c.zipc_create_sender("/6");

    while (true) {
        std.debug.print("will send\n", .{});
        const message = "hello!";
        sender.send(message);
        _ = os.nanosleep(0, 200_000_000);
    }
}
