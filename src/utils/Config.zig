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
is_allocated: bool = false,

pub fn init(io: Io, environ_map: *Map, allocator: Allocator) Config {
    return .{
        .io = io,
        .environ_map = environ_map,
        .allocator = allocator,
        .is_allocated = false,
    };
}

/// Resolves XDG_CONFIG_HOME or falls back to $HOME/.config.
/// Caller owns the returned slice and must free it.
fn resolveConfigDir(this: *Config) !?[]u8 {
    if (this.environ_map.get("XDG_CONFIG_HOME")) |dir| {
        return try this.allocator.dupe(u8, dir);
    }

    const home = this.environ_map.get("HOME") orelse return null;
    return try path.join(this.allocator, &.{ home, ".config" });
}

/// Resolves the absolute path to the module's ZON configuration file.
/// Caller owns the returned slice and must free it.
fn resolveModulePath(this: *Config, module_name: []const u8) !?[]u8 {
    const config_dir = try this.resolveConfigDir() orelse return null;
    defer this.allocator.free(config_dir);

    const config_file = try fmt.allocPrint(this.allocator, "{s}.zon", .{module_name});
    defer this.allocator.free(config_file);

    return try path.join(this.allocator, &.{ config_dir, "zig-waybar-contrib", config_file });
}

/// Checks whether a configuration file exists for the given module.
pub fn exists(this: *Config, module_name: []const u8) bool {
    const config_path = this.resolveModulePath(module_name) catch return false;
    defer this.allocator.free(config_path);

    var file = Dir.openFileAbsolute(this.io, config_path, .{ .mode = .read_only }) catch return false;
    file.close(this.io);

    return true;
}

/// Frees the allocated fields of a parsed configuration struct.
pub fn free(this: *Config, config: anytype) void {
    if (this.is_allocated) {
        zon.parse.free(this.allocator, config);
        this.is_allocated = false;
    }
}

/// Strictly loads a typed config struct `T`. Falls back to `T{}` on any error.
/// Caller is responsible for calling `free()` on success if `T` contains allocated fields.
pub fn load(this: *Config, module_name: []const u8, comptime T: type) T {
    return this.loadExact(module_name, T) catch {
        this.is_allocated = false;
        return T{};
    };
}

/// Strictly loads a typed config struct `T`. Bubbles up all internal errors.
pub fn loadExact(this: *Config, module_name: []const u8, comptime T: type) !T {
    const config_path = try this.resolveModulePath(module_name) orelse return error.ConfigDirNotFound;
    defer this.allocator.free(config_path);

    var file = try Dir.openFileAbsolute(this.io, config_path, .{ .mode = .read_only });
    defer file.close(this.io);

    const size = try file.length(this.io);
    const buffer = try this.allocator.allocSentinel(u8, size, 0);
    defer this.allocator.free(buffer);

    var reader = file.reader(this.io, &.{});
    try reader.interface.readSliceAll(buffer);

    const res = try zon.parse.fromSliceAlloc(T, this.allocator, buffer, null, .{ .ignore_unknown_fields = true, .free_on_error = true });
    this.is_allocated = true;
    return res;
}