// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 lumexren
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
const mem = std.mem;
const ascii = std.ascii;
const fmt = std.fmt;
const os = std.os;
const linux = os.linux;

pub const SysfsError = error{
    ReadFailed,
    InvalidValue,
};

/// Reads an integer from a sysfs file using raw Linux read syscall
/// to safely handle ENODATA and non-standard sysfs EOF conditions.
pub fn readInt(io: Io, dir: Dir, filename: []const u8, comptime T: type) !T {
    var file = dir.openFile(io, filename, .{}) catch return SysfsError.ReadFailed;
    defer file.close(io);

    var buf: [64]u8 = undefined;
    const rc = linux.read(file.handle, &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return SysfsError.ReadFailed;

    const trimmed = mem.trim(u8, buf[0..rc], &ascii.whitespace);
    return fmt.parseInt(T, trimmed, 10) catch SysfsError.InvalidValue;
}

/// Reads a millidegree or milli-value (e.g. 45000 -> 45000 i64).
pub inline fn readMilli(io: Io, dir: Dir, filename: []const u8) !i64 {
    return readInt(io, dir, filename, i64);
}

/// Reads a string from a sysfs file into caller-supplied buffer and trims whitespace.
pub fn readTrimmed(io: Io, dir: Dir, filename: []const u8, buf: []u8) ![]const u8 {
    var file = dir.openFile(io, filename, .{}) catch return SysfsError.ReadFailed;
    defer file.close(io);

    const rc = linux.read(file.handle, buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return SysfsError.ReadFailed;

    return mem.trim(u8, buf[0..rc], &ascii.whitespace);
}
