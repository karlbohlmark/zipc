//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.debug.print`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
}

test "simple test" {
    var list: std.ArrayList(i32) = .{};
    defer list.deinit(std.testing.allocator);
    try list.append(std.testing.allocator, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "shm_open" {
    const path: [*:0]const u8 = "/my-zipc-pahas";
    const flags: std.posix.O = .{
        .CREAT = true,
        .ACCMODE = .RDWR,
    };
    const fd = std.c.shm_open(path, @bitCast(flags), 0o600);
    try std.testing.expect(fd != -1);
    // Clean up
    _ = std.c.shm_unlink(path);
}
