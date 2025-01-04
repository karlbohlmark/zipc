const std = @import("std");

pub fn open(allocator: std.mem.Allocator, name: []const u8, flags: std.posix.O, mode: u16) std.os.linux.fd_t {
    std.debug.print("shm_open call for name {s}\n", .{name});
    const dir = "/dev/shm/";
    // Check that the name starts with a slash ('/') as required by POSIX
    if (name.len == 0 or name[0] != '/') {
        std.debug.print("name len: {} name {s}", .{ name.len, name });
        std.debug.assert(false);
    }
    const full_path = std.mem.concat(allocator, u8, &[_][]const u8{ dir, name[1..], "\x00"[0..1] }) catch {
        std.process.exit(1);
    };
    // std.debug.print("len2: {}, full path 2 {s} final char2: {}\n", .{ full_path.len, full_path, full_path[full_path.len - 1] });
    defer allocator.free(full_path);
    const path_ptr: [*:0]const u8 = @ptrCast(full_path.ptr);
    // Open or create the shared memory object
    const fd = std.os.linux.open(path_ptr, flags, mode);
    std.debug.assert(fd != -1);
    return @intCast(fd);
}

pub fn unlink(allocator: std.mem.Allocator, name: []const u8) void {
    const dir = "/dev/shm/";
    // Check that the name starts with a slash ('/') as required by POSIX
    if (name.len == 0 or name[0] != '/') {
        std.debug.print("name len: {} name {s}", .{ name.len, name });
        std.debug.assert(false);
    }
    const full_path = std.mem.concat(allocator, u8, &[_][]const u8{ dir, name[1..], "\x00"[0..1] }) catch {
        std.process.exit(1);
    };
    defer allocator.free(full_path);
    const path_ptr: [*:0]const u8 = @ptrCast(full_path.ptr);
    // Unlink the shared memory object
    const result = std.os.linux.unlink(path_ptr);
    std.debug.assert(result == 0);
}
