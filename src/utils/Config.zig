// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 erffy
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

/// Handles loading module configuration
const Config = @This();

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const path = Dir.path;
const zon = std.zon;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;
const process = std.process;
const Environ = process.Environ;
const Map = Environ.Map;

io: Io,
environ_map: *Map,
allocator: Allocator,

pub fn init(io: Io, environ_map: *Map, allocator: Allocator) Config {
    return .{ .io = io, .environ_map = environ_map, .allocator = allocator };
}

/// Load configuration
///
/// If config file doesn't exist or fails to parse, returns a default instance.
pub fn load(this: *Config, module_name: []const u8, comptime T: type) !T {
    const config_dir = this.environ_map.get("XDG_CONFIG_HOME") orelse
        if (this.environ_map.get("HOME")) |home| blk: {
            break :blk try path.join(this.allocator, &.{ home, ".config" });
        } else return T{};

    defer if (this.environ_map.get("XDG_CONFIG_HOME") == null) this.allocator.free(config_dir);

    const config_file = try fmt.allocPrint(this.allocator, "{s}.zon", .{module_name});
    defer this.allocator.free(config_file);

    const config_path = try path.join(this.allocator, &.{ config_dir, "zig-waybar-contrib", config_file });
    defer this.allocator.free(config_path);

    var file = Dir.openFileAbsolute(this.io, config_path, .{ .mode = .read_only }) catch return T{};
    defer file.close(this.io);

    const size = try file.length(this.io);
    const buffer = try this.allocator.allocSentinel(u8, size, 0);
    defer this.allocator.free(buffer);

    var reader = file.reader(this.io, &.{});
    try reader.interface.readSliceAll(buffer);

    return zon.parse.fromSliceAlloc(T, this.allocator, buffer, null, .{ .ignore_unknown_fields = true }) catch T{};
}
