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
};

/// Process information retrieved from /proc filesystem.
pub const Process = struct {
    /// Process name from /proc/<pid>/comm.
    name: []const u8,
    /// Process ID (pid).
    pid: linux.pid_t,

    /// Send a real-time signal relative to SIGRTMIN (e.g., 1 means SIGRTMIN+1).
    pub inline fn sendRtSignal(this: @This(), offset: u8) !void {
        try posix.kill(this.pid, @enumFromInt(linux.sigrtmin() + offset));
    }

    /// Send a real-time signal relative to SIGRTMAX (e.g., 1 means SIGRTMAX-1).
    pub inline fn sendRtMaxSignal(this: @This(), offset: u8) !void {
        try posix.kill(this.pid, @enumFromInt(linux.sigrtmax() - offset));
    }

    /// Send an arbitrary signal to the process.
    pub inline fn sendSignal(this: @This(), sig: i32) !void {
        try posix.kill(this.pid, @enumFromInt(sig));
    }

    /// Request graceful termination via SIGTERM.
    pub inline fn terminate(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.TERM);
    }

    /// Force kill via SIGKILL.
    pub inline fn kill(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.KILL);
    }

    /// Suspend the process via SIGSTOP.
    pub inline fn pause(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.STOP);
    }

    /// Resume the process via SIGCONT. Named `resume_` since `resume` is reserved.
    pub inline fn resume_(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.CONT);
    }

    /// Check if the process is running by testing /proc/<pid> accessibility.
    pub fn isAlive(this: @This(), io: Io) bool {
        var buf: [32]u8 = undefined;
        const path = fmt.bufPrint(&buf, "/proc/{d}", .{this.pid}) catch return false;
        Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }

    /// Read the full command line from /proc/<pid>/cmdline as a null-separated blob.
    /// Caller owns the returned slice and must free it.
    pub fn getCmdline(this: @This(), io: Io, allocator: Allocator) ![]u8 {
        var buf: [32]u8 = undefined;
        const path = try fmt.bufPrint(&buf, "/proc/{d}/cmdline", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        return file.readToEndAlloc(io, allocator, 4096);
    }
};

/// Iterator for finding all processes matching a given name.
/// Returned Process entries hold borrowed slices from target_name.
pub const ProcessIterator = struct {
    /// Opened /proc directory handle (caller must call deinit).
    dir: Dir,
    /// Directory iterator for scanning /proc entries.
    it: Dir.Iterator,
    /// Target process name to match.
    target_name: []const u8,
    /// I/O handle for filesystem operations.
    io: Io,

    /// Find the next matching process, or null if exhausted.
    pub fn next(this: *@This()) !?Process {
        while (try this.it.next(this.io)) |entry| {
            if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

            var buf: [64]u8 = undefined;
            const name = readProcName(this.io, entry.name, &buf) catch continue;
            if (!mem.eql(u8, name, this.target_name)) continue;

            const pid = try fmt.parseInt(linux.pid_t, entry.name, 10);
            return .{ .name = this.target_name, .pid = pid };
        }

        return null;
    }

    /// Close the directory handle.
    pub inline fn deinit(this: *@This()) void {
        this.dir.close(this.io);
    }
};

/// Find a single process by name, returning the first match or null.
/// Searches /proc by iterating directory entries.
pub fn findByName(io: Io, name: []const u8) !?Process {
    var dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

        var buf: [64]u8 = undefined;
        const proc_name = readProcName(io, entry.name, &buf) catch continue;
        if (!mem.eql(u8, proc_name, name)) continue;

        const pid = try fmt.parseInt(linux.pid_t, entry.name, 10);
        return .{ .name = name, .pid = pid };
    }

    return null;
}

/// Create an iterator for finding all processes matching a name.
/// Use ProcessIterator.next() to iterate and ProcessIterator.deinit() when done.
pub fn findAllByName(io: Io, name: []const u8) !ProcessIterator {
    const dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });
    return .{ .dir = dir, .it = dir.iterate(), .target_name = name, .io = io };
}

/// Find a process by its PID.
/// Returns NotFound if the process does not exist or /proc/<pid>/comm is inaccessible.
pub fn findByPid(io: Io, pid: linux.pid_t) !Process {
    var buf: [64]u8 = undefined;
    const path = try fmt.bufPrint(&buf, "/proc/{d}/comm", .{pid});

    const file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return ProcessError.NotFound;
    defer file.close(io);

    var name_buf: [64]u8 = undefined;
    var slices: [1][]u8 = .{name_buf[0..]};
    const n = try file.readStreaming(io, slices[0..]);

    return .{ .name = mem.trimEnd(u8, name_buf[0..n], &ascii.whitespace), .pid = pid };
}

/// Execute a command and return its exit code.
/// Streams to /dev/null; does not capture output.
pub fn runCommand(io: Io, argv: []const []const u8) !u8 {
    if (argv.len == 0) return error.EmptyCommand;

    var child = try process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .pipe });
    const term = try child.wait(io);

    return switch (term) {
        .exited => |code| code,
        .signal => error.TerminatedBySignal,
        .stopped => error.ProcessStopped,
        .unknown => error.UnknownTermination,
    };
}

/// Read and trim a process name from /proc/<pid_str>/comm into buf.
fn readProcName(io: Io, pid_str: []const u8, buf: *[64]u8) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = try fmt.bufPrint(&path_buf, "/proc/{s}/comm", .{pid_str});

    const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var slices: [1][]u8 = .{buf[0..]};
    const n = try file.readStreaming(io, slices[0..]);

    return mem.trimEnd(u8, buf[0..n], &ascii.whitespace);
}

/// Read an entire file into a newly allocated buffer.
/// Caller owns the returned slice and must free it.
pub fn readAll(io: Io, allocator: Allocator, file: File) ![]u8 {
    var buffer: [1024]u8 = undefined;
    var f_reader = file.reader(io, &buffer);
    const reader = &f_reader.interface;
    return reader.allocRemaining(allocator, .unlimited);
}

/// Search PATH for an executable by name.
/// Caller owns the returned slice and must free it.
pub fn findExecutable(io: Io, environ_map: *Map, allocator: Allocator, exe_name: []const u8) !?[]u8 {
    const path_value = environ_map.get("PATH") orelse return null;

    var it = mem.splitScalar(u8, path_value, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = try Dir.path.join(allocator, &.{ dir, exe_name });

        if (Dir.accessAbsolute(io, full_path, .{ .execute = true })) {
            return try allocator.dupe(u8, full_path);
        } else |_| {}
    }

    return null;
}