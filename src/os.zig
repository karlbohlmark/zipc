const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.zipc);

pub const Error = error{
    InvalidName,
    NameTooLong,
    OpenFailed,
    TruncateFailed,
    AllocateFailed,
    MapFailed,
};

const shm_dir = switch (builtin.target.os.tag) {
    .linux => "/dev/shm/",
    // macOS shm objects are kernel names, not filesystem paths; shmPath
    // returns the name itself there.
    .macos => "",
    else => @compileError("zipc: unsupported OS"),
};

/// Longest supported channel name, including the leading '/'. Note macOS
/// enforces its own, shorter shm name limit (PSHMNAMLEN, 31).
pub const max_name_len = 39;

/// Buffer large enough for shmPath's result.
pub const PathBuffer = [shm_dir.len + max_name_len + 1]u8;

/// Builds the OS-level identifier for a channel name: "/dev/shm/foo" on
/// Linux, the raw shm object name ("/foo") on macOS. The returned pointer
/// aliases `buf`.
pub fn shmPath(buf: *PathBuffer, name: []const u8) Error![*:0]const u8 {
    if (name.len == 0 or name[0] != '/') return Error.InvalidName;
    // POSIX shm names must not contain further slashes; allowing them would
    // let a name escape the shm directory on Linux.
    if (std.mem.indexOfScalarPos(u8, name, 1, '/') != null) return Error.InvalidName;
    if (name.len > max_name_len) return Error.NameTooLong;
    if (builtin.target.os.tag == .linux) {
        @memcpy(buf[0..shm_dir.len], shm_dir);
        @memcpy(buf[shm_dir.len..][0 .. name.len - 1], name[1..]);
        buf[shm_dir.len + name.len - 1] = 0;
    } else {
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
    }
    return @ptrCast(buf);
}

/// Removes the shm object backing a channel name.
pub fn shmUnlink(name: []const u8) Error!void {
    var buf: PathBuffer = undefined;
    const path = try shmPath(&buf, name);
    switch (builtin.target.os.tag) {
        .linux => unlink(path),
        .macos => _ = std.c.shm_unlink(path),
        else => comptime unreachable,
    }
}

pub fn shm_open(name: []const u8, flags: std.posix.O, mode: u16) Error!std.posix.fd_t {
    var buf: PathBuffer = undefined;
    const path = try shmPath(&buf, name);
    switch (builtin.target.os.tag) {
        .linux => {
            const rc = std.os.linux.open(path, flags, mode);
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) {
                log.err("open({s}) failed: {s}", .{ path, @tagName(err) });
                return Error.OpenFailed;
            }
            return @intCast(rc);
        },
        .macos => {
            const fd = std.c.shm_open(path, @bitCast(flags), mode);
            if (fd < 0) return Error.OpenFailed;
            return @intCast(fd);
        },
        else => comptime unreachable,
    }
}

pub fn close(fd: std.posix.fd_t) void {
    switch (builtin.target.os.tag) {
        .linux => _ = std.os.linux.close(fd),
        .macos => _ = std.c.close(fd),
        else => comptime unreachable,
    }
}

pub fn unlink(path: [*:0]const u8) void {
    switch (builtin.target.os.tag) {
        .linux => {
            const rc = std.os.linux.unlink(path);
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS and err != .NOENT) {
                log.warn("unlink({s}) failed: {s}", .{ path, @tagName(err) });
            }
        },
        .macos => _ = std.c.unlink(path),
        else => comptime unreachable,
    }
}

pub fn ftruncate(fd: std.posix.fd_t, length: u64) Error!void {
    switch (builtin.target.os.tag) {
        .linux => {
            const rc = std.os.linux.ftruncate(fd, @intCast(length));
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) {
                log.err("ftruncate({} bytes) failed: {s}", .{ length, @tagName(err) });
                return Error.TruncateFailed;
            }
        },
        .macos => {
            if (std.c.ftruncate(fd, @intCast(length)) != 0) {
                // macOS shm objects can only be sized once; a second
                // ftruncate on an already-sized object fails. Tolerate that
                // when the existing size already matches.
                var st: std.c.Stat = undefined;
                if (std.c.fstat(fd, &st) != 0) return Error.TruncateFailed;
                if (st.size != @as(@TypeOf(st.size), @intCast(length))) return Error.TruncateFailed;
            }
        },
        else => comptime unreachable,
    }
}

/// Reserves backing pages for the whole segment up front, so that tmpfs
/// exhaustion fails here - at create time, with an error - instead of as a
/// SIGBUS on first touch inside send(). ftruncate alone only sets the size;
/// tmpfs allocates pages lazily and happily overcommits.
pub fn preallocate(fd: std.posix.fd_t, length: u64) Error!void {
    switch (builtin.target.os.tag) {
        .linux => {
            const rc = std.os.linux.fallocate(fd, 0, 0, @intCast(length));
            const err = std.os.linux.errno(rc);
            switch (err) {
                .SUCCESS => {},
                // Filesystem cannot preallocate; keep the lazy behavior.
                .OPNOTSUPP, .NOSYS => {},
                else => {
                    log.err("fallocate({} bytes) failed: {s}", .{ length, @tagName(err) });
                    return Error.AllocateFailed;
                },
            }
        },
        .macos => {},
        else => comptime unreachable,
    }
}

/// Maps the whole segment read-write, shared.
pub fn mmap(fd: std.posix.fd_t, length: usize, offset: usize) Error![]align(8) u8 {
    switch (builtin.target.os.tag) {
        .linux => {
            const rc = std.os.linux.mmap(null, length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(offset));
            const err = std.os.linux.errno(rc);
            if (err != .SUCCESS) {
                log.err("mmap({} bytes) failed: {s}", .{ length, @tagName(err) });
                return Error.MapFailed;
            }
            const ptr: [*]align(8) u8 = @ptrFromInt(rc);
            return ptr[0..length];
        },
        .macos => {
            const ptr_anyopaque = std.c.mmap(null, length, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(offset));
            if (ptr_anyopaque == std.c.MAP_FAILED) return Error.MapFailed;
            const ptr: [*]align(8) u8 = @ptrCast(@alignCast(ptr_anyopaque));
            return ptr[0..length];
        },
        else => comptime unreachable,
    }
}

/// Monotonic clock reading in nanoseconds.
pub fn monotonicNanos() u64 {
    switch (builtin.target.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
        .macos => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
        },
        else => comptime unreachable,
    }
}

pub fn munmap(ptr: [*]align(8) const u8, length: usize) void {
    switch (builtin.target.os.tag) {
        .linux => _ = std.os.linux.munmap(ptr, length),
        .macos => _ = std.c.munmap(@ptrCast(@alignCast(@constCast(ptr))), length),
        else => comptime unreachable,
    }
}

pub fn nanosleep(sec: u64, nsec: u32) void {
    // Early return on EINTR is fine: every caller re-checks its own
    // condition in a loop.
    switch (builtin.target.os.tag) {
        .linux => {
            const timespec = std.os.linux.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            _ = std.os.linux.nanosleep(&timespec, null);
        },
        .macos => {
            const timespec = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
            _ = std.c.nanosleep(&timespec, null);
        },
        else => comptime unreachable,
    }
}

pub fn getpid() i32 {
    switch (builtin.target.os.tag) {
        .linux => return std.os.linux.getpid(),
        .macos => return std.c.getpid(),
        else => comptime unreachable,
    }
}
