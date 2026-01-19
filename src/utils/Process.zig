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
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const posix = std.posix;
const process = std.process;
const Child = process.Child;
const os = std.os;
const linux = os.linux;

pub const ProcessError = error{
    NotFound,
    InvalidPid,
    AccessDenied,
};

pub const Process = struct {
    name: []const u8,
    pid: linux.pid_t,

    /// Send a real-time signal (SIGRTMIN + offset) to this process
    pub fn sendRtSignal(this: @This(), offset: u8) !void {
        const sig = linux.sigrtmin() + offset;
        try posix.kill(this.pid, @enumFromInt(sig));
    }

    /// Send a real-time signal (SIGRTMAX - offset) to this process
    pub fn sendRtMaxSignal(this: @This(), offset: u8) !void {
        const sig = linux.sigrtmax() - offset;
        try posix.kill(this.pid, @enumFromInt(sig));
    }

    /// Send any signal to this process
    pub fn sendSignal(this: @This(), sig: i32) !void {
        try posix.kill(this.pid, @enumFromInt(sig));
    }

    /// Terminate the process gracefully (SIGTERM)
    pub fn terminate(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.TERM);
    }

    /// Force kill the process (SIGKILL)
    pub fn kill(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.KILL);
    }

    /// Pause the process (SIGSTOP)
    pub fn pause(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.STOP);
    }

    /// Resume the process (SIGCONT)
    pub fn resume_(this: @This()) !void {
        try posix.kill(this.pid, linux.SIG.CONT);
    }

    /// Check if this process is still alive
    pub fn isAlive(this: @This(), io: Io) bool {
        var path_buffer: [32]u8 = undefined;
        const path = fmt.bufPrint(&path_buffer, "/proc/{d}", .{this.pid}) catch return false;
        Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }

    /// Get the command line arguments of this process
    pub fn getCmdline(this: @This(), io: Io, allocator: Allocator) ![]const u8 {
        var path_buffer: [32]u8 = undefined;
        const path = try fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{this.pid});

        const file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
        defer file.close(io);

        const max_size = 4096;
        var buffer = try allocator.alloc(u8, max_size);
        defer allocator.free(buffer);

        var slices: [1][]u8 = .{buffer[0..]};
        const n = try file.readStreaming(io, slices[0..]);

        return allocator.realloc(buffer, n);
    }
};

/// Iterator for finding processes by name
pub const ProcessIterator = struct {
    dir: Dir,
    it: Dir.Iterator,
    target_name: []const u8,
    io: Io,

    /// Get the next matching process
    pub fn next(this: *@This()) !?Process {
        while (try this.it.next(this.io)) |entry| {
            if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

            var path_buffer: [64]u8 = undefined;
            const path = try fmt.bufPrint(&path_buffer, "/proc/{s}/comm", .{entry.name});

            const file = Dir.openFileAbsolute(this.io, path, .{ .mode = .read_only }) catch continue;
            defer file.close(this.io);

            var name_buffer: [64]u8 = undefined;
            var slices: [1][]u8 = .{name_buffer[0..]};
            const n = try file.readStreaming(this.io, slices[0..]);

            const proc_name = mem.trimEnd(u8, name_buffer[0..n], &ascii.whitespace);

            if (mem.eql(u8, proc_name, this.target_name)) {
                const pid = try fmt.parseInt(linux.pid_t, entry.name, 10);
                return .{ .name = this.target_name, .pid = pid };
            }
        }

        return null;
    }

    pub fn deinit(this: *@This()) void {
        this.dir.close(this.io);
    }
};

/// Find the first process matching the given name
pub fn findByName(io: Io, name: []const u8) !?Process {
    var dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !ascii.isDigit(entry.name[0])) continue;

        var path_buffer: [64]u8 = undefined;
        const path = try fmt.bufPrint(&path_buffer, "/proc/{s}/comm", .{entry.name});

        const file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch continue;
        defer file.close(io);

        var name_buffer: [64]u8 = undefined;
        var slices: [1][]u8 = .{name_buffer[0..]};
        const n = try file.readStreaming(io, slices[0..]);

        const proc_name = mem.trimEnd(u8, name_buffer[0..n], &ascii.whitespace);

        if (mem.eql(u8, proc_name, name)) {
            const pid = try fmt.parseInt(linux.pid_t, entry.name, 10);
            return .{ .name = name, .pid = pid };
        }
    }

    return null;
}

/// Create an iterator to find all processes matching the given name
pub fn findAllByName(io: Io, name: []const u8) !ProcessIterator {
    const dir = try Dir.openDirAbsolute(io, "/proc", .{ .iterate = true, .follow_symlinks = false });

    return .{ .dir = dir, .it = dir.iterate(), .target_name = name, .io = io };
}

/// Find a process by its PID
pub fn findByPid(io: Io, pid: linux.pid_t) !Process {
    var path_buffer: [64]u8 = undefined;
    const comm_path = try fmt.bufPrint(&path_buffer, "/proc/{d}/comm", .{pid});

    const file = Dir.openFileAbsolute(io, comm_path, .{ .mode = .read_only }) catch return ProcessError.NotFound;
    defer file.close(io);

    var name_buffer: [64]u8 = undefined;
    var slices: [1][]u8 = .{name_buffer[0..]};
    const n = try file.readStreaming(io, slices[0..]);

    const proc_name = mem.trimEnd(u8, name_buffer[0..n], &ascii.whitespace);

    return .{ .name = proc_name, .pid = pid };
}

pub fn runCommand(io: Io, argv: []const []const u8) !u8 {
    if (argv.len == 0) return error.EmptyCommand;

    var child: Child = try process.spawn(io, .{
      .argv = argv,
      .stdout = .pipe,
      .stderr = .pipe,
    });

    const term = try child.wait(io);

    return switch (term) {
        .exited => |code| code,
        .signal => return error.TerminatedBySignal,
        .stopped => return error.ProcessStopped,
        .unknown => return error.UnknownTermination,
    };
}
