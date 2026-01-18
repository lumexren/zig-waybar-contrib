// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 - 2026 erffy
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

pub const Config = @import("config.zig");
pub const network = @import("network.zig");
pub const process = @import("process.zig");
pub const Waybar = @import("waybar.zig");
pub const json = @import("json.zig");
pub const Replacer = @import("replacer.zig");
pub const output = @import("output.zig");

const std = @import("std");
const Environ = std.process.Environ;
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const path = Dir.path;
const mem = std.mem;
const Allocator = mem.Allocator;

const ESCAPE_MAP = init: {
    var map: [256]u8 = undefined;
    for (0..256) |i| map[i] = @as(u8, @truncate(i));

    map['"'] = '\\';
    map['\\'] = '\\';
    map['\n'] = 'n';
    map['\r'] = 'r';
    map['\t'] = 't';
    break :init map;
};

pub fn readAll(allocator: Allocator, io: Io, file: Io.File) ![]u8 {
    var buffer: [1024]u8 = undefined;
    var f_reader = file.reader(io, &buffer);
    const reader = &f_reader.interface;
    return reader.allocRemaining(allocator, .unlimited);
}

pub inline fn escapeJson(input: []const u8, out_buf: []u8) void {
    var j: usize = 0;
    for (input) |char| {
        if (j >= out_buf.len - 1) break;

        const escaped = ESCAPE_MAP[char];
        if (escaped != char) {
            if (j + 2 >= out_buf.len) break;
            out_buf[j] = '\\';
            j += 1;
            out_buf[j] = escaped;
        } else out_buf[j] = char;

        j += 1;
    }

    out_buf[j] = 0;
}

pub fn findExecutable(environ: Environ, allocator: Allocator, io: Io, exe_name: []const u8) !?[]u8 {
    const path_value = environ.getPosix("PATH") orelse return null;

    var it = mem.splitScalar(u8, path_value, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        const full_path = try path.join(allocator, &.{ dir, exe_name });

        if (Dir.accessAbsolute(io, full_path, .{ .execute = true })) {
            return try allocator.dupe(u8, full_path);
        } else |_| {}
    }

    return null;
}

pub fn readFileBytes(allocator: Allocator, file_path: []const u8, max_bytes: usize) ![]u8 {
    return Dir.readFileAlloc(allocator, file_path, max_bytes);
}
