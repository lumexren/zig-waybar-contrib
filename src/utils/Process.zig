// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 erffy
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://gnu.org/licenses>.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const ascii = std.ascii;
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;
const os = std.os;
const linux = os.linux;

/// Errors returned by process operations.
pub const ProcessError = error{
    /// Process or executable not found.
    NotFound,
    /// Invalid process ID format.
    InvalidPid,
    /// Permission denied accessing process resources.
    AccessDenied,
    /// The command argv slice was empty.
    EmptyCommand,
    /// The spawned process was terminated by a signal.
    TerminatedBySignal,
    /// The spawned process was stopped unexpectedly.
    ProcessStopped,
    /// The spawned process exited with an unknown status.
    UnknownTermination,
};

// Maximum bytes read from /proc/<pid>/comm (kernel caps comm at 16 bytes + newline).
const comm_buf_len = 20;
// Maximum bytes read from /proc/<pid>/cmdline (4 KiB is typical page size).
const cmdline_max = 4096;

/// Process information retrieved from the /proc filesystem.
pub const Process = struct {
    /// Process name from /proc/<pid>/comm (trimmed, null-terminated for free).
    name: []const u8,
    /// Process ID.
    pid: linux.pid_t,

    /// Send a real-time signal at SIGRTMIN + `offset`.
    pub inline fn sendRtSignal(this: @This(), offset: u8) !void {
        try posix.kill(this.pid, @enumFromInt(linux.sigrtmin() + @as(i32, offset)));
    }

    /// Send a real-time signal at SIGRTMAX - `offset`.
    pub inline fn sendRtMaxSignal(this: @This(), offset: u8) !void {
        try posix.kill(this.pid, @enumFromInt(linux.sigrtmax() - @as(i32, offset)));
    }

    /// Send an arbitrary signal number to the process.
    pub inline fn sendSignal(this: @This(), sig: i32) !void {
        try posix.kill(this.pid, @enumFromInt(sig));
    }

    /// Request graceful termination (SIGTERM).
    pub inline fn terminate(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.TERM);
    }

    /// Force kill the process (SIGKILL).
    pub inline fn kill(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.KILL);
    }

    /// Suspend the process (SIGSTOP).
    pub inline fn pause(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.STOP);
    }

    /// Resume a suspended process (SIGCONT). Named `resume_` because `resume` is reserved.
    pub inline fn resume_(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.CONT);
    }

    /// Check whether the process is still alive.
    ///
    /// Uses `kill(pid, 0)` — a single syscall with no filesystem I/O, making
    /// this significantly cheaper than the previous /proc access approach.
    /// Returns `false` for ESRCH (not found) and EPERM (no permission to signal,
    /// but the process exists — treated conservatively as alive).
    pub fn isAlive(this: @This()) bool {
        posix.kill(this.pid, 0) catch |err| switch (err) {
            error.ProcessNotFound => return false,
            else => {}, // EPERM: process exists but we can't signal it → alive
        };
        return true;
    }

    /// Read the process's argv from /proc/<pid>/cmdline.
    ///
    /// The kernel stores cmdline as NUL-separated tokens. The caller owns the
    /// returned slice and must free it with `allocator`.
    pub fn getCmdline(this: @This(), io: Io, allocator: Allocator) ![]u8 {
        var path_buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        return file.readToEndAlloc(io, allocator, cmdline_max);
    }

    /// Read the process's argv from /proc/<pid>/cmdline into `buf`.
    ///
    /// Returns the slice of `buf` that was written, capped at `buf.len`.
    /// Prefer this over `getCmdline` when you want to avoid an allocation.
    pub fn getCmdlineInto(this: @This(), io: Io, buf: []u8) ![]u8 {
        var path_buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var slices: [1][]u8 = .{buf};
        const n = try file.readStreaming(io, slices[0..]);
        return buf[0..n];
    }

    /// Read the process's environment from /proc/<pid>/environ.
    ///
    /// The kernel stores environ as NUL-separated KEY=VALUE pairs. Caller owns
    /// the returned slice and must free it with `allocator`.
    pub fn getEnviron(this: @This(), io: Io, allocator: Allocator) ![]u8 {
        var path_buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buf, "/proc/{d}/environ", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        return file.readToEndAlloc(io, allocator, 64 * 1024);
    }

    /// Read the process's current working directory from /proc/<pid>/cwd.
    ///
    /// Resolves the symlink and returns the path. Caller owns the returned
    /// slice and must free it with `allocator`.
    pub fn getCwd(this: @This(), io: Io, allocator: Allocator) ![]u8 {
        var path_buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buf, "/proc/{d}/cwd", .{this.pid});

        var result_buf: [fs.max_path_bytes]u8 = undefined;
        const resolved = try Dir.readLinkAbsolute(io, path, &result_buf);
        return allocator.dupe(u8, resolved);
    }

    /// Read a single field from /proc/<pid>/status by key (e.g. "VmRSS").
    ///
    /// Returns the raw value string (trimmed), or `null` if the key is absent.
    /// Uses stack storage only — no allocation.
    pub fn getStatusField(this: @This(), io: Io, key: []const u8, buf: []u8) !?[]const u8 {
        var path_buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buf, "/proc/{d}/status", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        var file_buf: [4096]u8 = undefined;
        var slices: [1][]u8 = .{file_buf[0..]};
        const n = try file.readStreaming(io, slices[0..]);
        const content = file_buf[0..n];

        var lines = mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (!mem.startsWith(u8, line, key)) continue;
            const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
            const value = mem.trim(u8, line[colon + 1 ..], &ascii.whitespace);
            if (value.len > buf.len) return error.NoSpaceLeft;
            @memcpy(buf[0..value.len], value);
            return buf[0..value.len];
        }

        return null;
    }
};

/// Iterator over all /proc entries that match a given process name.
///
/// Returned `Process` values borrow their `name` field from `target_name`,
/// so `target_name` must outlive all values produced by `next`.
pub const ProcessIterator = struct {
    dir: Dir,
    it: Dir.Iterator,
    target_name: []const u8,
    io: Io,

    /// Advance to the next matching process, or return `null` when exhausted.
    pub fn next(this: *@This()) !?Process {
        var comm_buf: [comm_buf_len]u8 = undefined;

        while (try this.it.next(this.io)) |entry| {
            // Only numeric directories correspond to PIDs.
            if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

            const name = readCommInto(this.io, entry.name, &comm_buf) catch continue;
            if (!mem.eql(u8, name, this.target_name)) continue;

            const pid = fmt.parseInt(linux.pid_t, entry.name, 10) catch continue;
            return .{ .name = this.target_name, .pid = pid };
        }

        return null;
    }

    /// Close the underlying /proc directory handle.
    pub inline fn deinit(this: *@This()) void {
        this.dir.close(this.io);
    }
};

/// Find the first process whose comm matches `name`.
///
/// Scans /proc by iterating directory entries. Returns `null` when not found.
pub fn findByName(io: Io, name: []const u8) !?Process {
    var dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);

    var it = dir.iterate();
    var comm_buf: [comm_buf_len]u8 = undefined;

    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

        const proc_name = readCommInto(io, entry.name, &comm_buf) catch continue;
        if (!mem.eql(u8, proc_name, name)) continue;

        const pid = fmt.parseInt(linux.pid_t, entry.name, 10) catch continue;
        return .{ .name = name, .pid = pid };
    }

    return null;
}

/// Return an iterator over all processes whose comm matches `name`.
///
/// Call `ProcessIterator.deinit()` when done to release the /proc handle.
pub fn findAllByName(io: Io, name: []const u8) !ProcessIterator {
    const dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });
    return .{ .dir = dir, .it = dir.iterate(), .target_name = name, .io = io };
}

/// Look up a process by PID.
///
/// Reads /proc/<pid>/comm to obtain the name. Returns `ProcessError.NotFound`
/// when the process does not exist or /proc/<pid>/comm is inaccessible.
///
/// Note: the returned `name` slice points into the caller-supplied `name_buf`.
/// `name_buf` must be at least `comm_buf_len` bytes (20 bytes).
pub fn findByPid(io: Io, pid: linux.pid_t, name_buf: *[comm_buf_len]u8) !Process {
    var pid_str_buf: [20]u8 = undefined;
    const pid_str = fmt.bufPrint(&pid_str_buf, "{d}", .{pid}) catch return ProcessError.InvalidPid;

    const name = readCommInto(io, pid_str, name_buf) catch return ProcessError.NotFound;
    return .{ .name = name, .pid = pid };
}

/// Execute a command and return its exit code.
///
/// stdout and stderr are discarded (`.ignore`). This avoids the latent
/// deadlock present when using `.pipe` without draining the pipe buffers.
pub fn runCommand(io: Io, argv: []const []const u8) !u8 {
    if (argv.len == 0) return ProcessError.EmptyCommand;

    var child = try process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);

    return switch (term) {
        .exited => |code| code,
        .signal => ProcessError.TerminatedBySignal,
        .stopped => ProcessError.ProcessStopped,
        .unknown => ProcessError.UnknownTermination,
    };
}

/// Execute a command and capture its stdout.
///
/// Returns the raw stdout bytes; caller owns and must free the slice.
/// stderr is discarded. On non-`.exited` termination the captured bytes
/// are freed and the appropriate error is returned.
pub fn runCommandCapture(io: Io, argv: []const []const u8, allocator: Allocator) ![]u8 {
    if (argv.len == 0) return ProcessError.EmptyCommand;

    var child = try process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout = try readAll(io, allocator, child.stdout.?);
    errdefer allocator.free(stdout);

    const term = try child.wait(io);
    return switch (term) {
        .exited => stdout,
        .signal => ProcessError.TerminatedBySignal,
        .stopped => ProcessError.ProcessStopped,
        .unknown => ProcessError.UnknownTermination,
    };
}

/// Read an entire file into a newly allocated buffer.
///
/// Uses a stack-local 4 KiB read buffer for I/O; only the final heap
/// allocation for the returned slice is made. Caller owns the slice.
pub fn readAll(io: Io, allocator: Allocator, file: File) ![]u8 {
    var io_buf: [4096]u8 = undefined;
    var f_reader = file.reader(io, &io_buf);
    const reader = &f_reader.interface;
    return reader.allocRemaining(allocator, .unlimited);
}

/// Search PATH for an executable, returning its full path or `null`.
///
/// Iterates the colon-separated PATH entries and checks each for execute
/// permission using a single `access(2)` call. Uses a stack buffer to
/// avoid per-entry heap allocations; only the successful hit is duplicated.
/// Caller owns the returned slice and must free it with `allocator`.
pub fn findExecutable(io: Io, environ_map: *Map, allocator: Allocator, exe_name: []const u8) !?[]u8 {
    const path_value = environ_map.get("PATH") orelse return null;

    // fs.max_path_bytes on Linux is PATH_MAX (4096); putting this on the stack
    // is intentional — it is a one-time frame allocation for the search loop.
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    var it = mem.splitScalar(u8, path_value, ':');

    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, exe_name }) catch continue;

        if (Dir.accessAbsolute(io, full_path, .{ .execute = true })) {
            return try allocator.dupe(u8, full_path);
        } else |_| {}
    }

    return null;
}

/// Read and trim /proc/<pid_str>/comm into `buf`.
///
/// `buf` must be at least `comm_buf_len` bytes. The returned slice is a
/// sub-slice of `buf` — its lifetime is tied to `buf`.
fn readCommInto(io: Io, pid_str: []const u8, buf: *[comm_buf_len]u8) ![]const u8 {
    var path_buf: [32]u8 = undefined;
    const path = try fmt.bufPrint(&path_buf, "/proc/{s}/comm", .{pid_str});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var slices: [1][]u8 = .{buf[0..]};
    const n = try file.readStreaming(io, slices[0..]);

    return mem.trimEnd(u8, buf[0..n], &ascii.whitespace);
}