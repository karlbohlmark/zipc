const std = @import("std");
const Zipc_c = @import("./zipc_c.zig").Zipc_c;
const zipc_c = Zipc_c(1536, 64);
// const zipc_c = Zipc_c(8, 4);

pub fn main() !void {
    var sender = zipc_c.zipc_create_sender("/my-zipc-path");

    while (true) {
        std.debug.print("will send\n", .{});
        const message = "hello!";
        sender.send(message);
        var rem: std.os.linux.timespec = undefined;
        const duration: std.os.linux.timespec = .{ .sec = 0, .nsec = 200_000_000 };
        _ = std.os.linux.nanosleep(&duration, &rem);
    }
}
