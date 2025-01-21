const std = @import("std");
const builtin = @import("builtin");

pub fn shm_open(allocator: std.mem.Allocator, name: []const u8, flags: std.posix.O, mode: u16) std.posix.fd_t {
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
    return switch (builtin.target.os.tag) {
        .linux => {
            const fd = std.os.linux.open(path_ptr, flags, mode);
            std.debug.assert(fd != -1);
            return @intCast(fd);
        },
        .macos => {
            const fd = std.c.shm_open(path_ptr, @bitCast(flags), mode);
            std.debug.assert(fd != -1);
            return @intCast(fd);
        },
        else => {
            std.debug.panic("shm_open not implemented for this OS");
        },
    };
}

pub fn unlink(path: [*:0]const u8) void {
    switch (builtin.target.os.tag) {
        .linux => {
            const result = std.os.linux.unlink(path);
            std.debug.assert(result == 0);
        },
        .macos => {
            const result = std.c.unlink(path);
            std.debug.assert(result == 0);
        },
        else => {
            std.debug.panic("unlink not implemented for this OS");
        },
    }
}

// const dir = "/dev/shm/";
// // Check that the name starts with a slash ('/') as required by POSIX
// if (name.len == 0 or name[0] != '/') {
//     std.debug.print("name len: {} name {s}", .{ name.len, name });
//     std.debug.assert(false);
// }
// const full_path = std.mem.concat(allocator, u8, &[_][]const u8{ dir, name[1..], "\x00"[0..1] }) catch {
//     std.process.exit(1);
// };
// defer allocator.free(full_path);

pub fn ftruncate(fd: std.posix.fd_t, length: u64) void {
    switch (builtin.target.os.tag) {
        .linux => {
            const result = std.os.linux.ftruncate(fd, length);
            std.debug.assert(result == 0);
        },
        .macos => {
            const result = std.c.ftruncate(fd, length);
            std.debug.assert(result == 0);
        },
        else => {
            std.debug.panic("ftruncate not implemented for this OS");
        },
    }
}

pub fn map(fd: std.posix.fd_t, length: usize, prot: std.posix.PROT, flags: std.posix.MAP, offset: usize) []u8 {
    switch (builtin.target.os.tag) {
        .linux => {
            const ptr = std.os.linux.mmap(null, length, prot, flags, fd, offset);
            std.debug.assert(ptr != null);
            return std.mem.slice(ptr, length);
        },
        .macos => {
            const ptr = std.c.mmap(null, length, prot, flags, fd, offset);
            std.debug.assert(ptr != null);
            return std.mem.slice(ptr, length);
        },
        else => {
            std.debug.panic("mmap not implemented for this OS");
        },
    }
}

pub fn nanosleep(sec: u64, nsec: u32) void {
    switch (builtin.target.os.tag) {
        .linux => {
            const timespec = std.os.linux.timespec{
                .sec = @intCast(sec),
                .nsec = @intCast(nsec),
            };
            const result = std.os.linux.nanosleep(&timespec, null);
            std.debug.assert(result == 0);
        },
        .macos => {
            const timespec = std.c.timespec{
                .sec = @intCast(sec),
                .nsec = @intCast(nsec),
            };
            const result = std.c.nanosleep(&timespec, null);
            std.debug.assert(result == 0);
        },
        else => {
            std.debug.panic("nanosleep not implemented for this OS");
        },
    }
}

pub fn getpid() i32 {
    switch (builtin.target.os.tag) {
        .linux => return std.os.linux.getpid(),
        .macos => return std.c.getpid(),
        else => std.debug.panic("getpid not implemented for this OS"),
    }
}
