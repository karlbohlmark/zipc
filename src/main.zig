//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    // Prints to stderr (it's a shortcut based on `std.debug.print`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});
    try stdout.flush();
}

test "simple test" {
    var list: std.ArrayList(i32) = .empty;
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
