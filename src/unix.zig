const std = @import("std");

pub fn bindUnixSocket(path: []const u8) std.os.linux.fd_t {
    const fd_return: usize = std.os.linux.socket(
        std.os.linux.AF.UNIX,
        std.os.linux.SOCK.DGRAM,
        0,
    );
    if (fd_return == -1) {
        std.debug.lockStdErr();
        std.debug.print("failed to create control socket\n", .{});
        std.debug.unlockStdErr();
        std.process.exit(1);
    }
    const fd: i32 = @intCast(fd_return);
    var addr: std.os.linux.sockaddr.un = undefined;
    addr.family = std.os.linux.AF.UNIX;
    addr.path[0] = 0; // Abstract namespace indicator
    const path_len = path.len;
    std.mem.copyForwards(u8, addr.path[1 .. 1 + path_len], path);
    // Ensure the remaining bytes in addr.path are zeroed
    @memset(addr.path[1 + path_len ..], 0);
    const addr_len: u32 = @intCast(@sizeOf(std.os.linux.sa_family_t) + path_len + 1);
    if (std.os.linux.bind(fd, @ptrCast(&addr), addr_len) == -1) {
        std.debug.lockStdErr();
        std.debug.print("failed to bind control socket\n", .{});
        std.debug.unlockStdErr();
        std.os.linux.close(fd);
        std.process.exit(1);
    }
    return @intCast(fd);
}
