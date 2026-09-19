// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 erenvly
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

const BenchmarkResult = @This();

const std = @import("std");
const fmt = std.fmt;

name: []const u8,
iterations: u64,
total_ns: u64,
mean_ns: f64,
ops_per_sec: f64,
allocs_per_op: f64,
peak_bytes: usize,
leaked_bytes: usize,

pub fn formatDuration(ns: f64, buf: []u8) []const u8 {
    if (ns < 1000.0) {
        return fmt.bufPrint(buf, "{d:.1} ns", .{ns}) catch "---";
    } else if (ns < 1_000_000.0) {
        return fmt.bufPrint(buf, "{d:.2} µs", .{ns / 1000.0}) catch "---";
    } else if (ns < 1_000_000_000.0) {
        return fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000.0}) catch "---";
    } else {
        return fmt.bufPrint(buf, "{d:.2} s", .{ns / 1_000_000_000.0}) catch "---";
    }
}

pub fn formatBytes(bytes: usize, buf: []u8) []const u8 {
    if (bytes < 1024) {
        return fmt.bufPrint(buf, "{d} B", .{bytes}) catch "---";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return fmt.bufPrint(buf, "{d:.1} KiB", .{kb}) catch "---";
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return fmt.bufPrint(buf, "{d:.2} MiB", .{mb}) catch "---";
    }
}
