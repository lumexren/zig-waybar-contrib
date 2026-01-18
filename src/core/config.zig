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

io: Io,
environ: Environ,
allocator: Allocator,

pub fn init(io: Io, environ: Environ, allocator: Allocator) Config {
    return .{ .io = io, .environ = environ, .allocator = allocator };
}

/// Load configuration
/// 
/// If config file doesn't exist or fails to parse, returns a default instance.
pub fn load(this: *Config, module_name: []const u8, comptime T: type) !T {
    var data: T = T{};

    const config_file = try fmt.allocPrint(this.allocator, "{s}.zon", .{module_name});
    var config_path: []u8 = undefined;

    if (this.environ.getPosix("XDG_CONFIG_HOME")) |xdg_config_home_dir| {
        config_path = try path.join(this.allocator, &.{ xdg_config_home_dir, "zig-waybar-contrib", config_file });
    } else if (this.environ.getPosix("HOME")) |home_dir| {
        config_path = try path.join(this.allocator, &.{ home_dir, ".config", "zig-waybar-contrib", config_file });
    }

    var file = Dir.openFileAbsolute(this.io, config_path, .{ .mode = .read_only }) catch return data;
    defer file.close(this.io);

    const size = try file.length(this.io);
    const buffer = try this.allocator.allocSentinel(u8, size, 0);

    var reader = file.reader(this.io, &.{});
    try reader.interface.readSliceAll(buffer);

    data = zon.parse.fromSliceAlloc(T, this.allocator, buffer, null, .{ .ignore_unknown_fields = true }) catch return data;

    return data;
}
