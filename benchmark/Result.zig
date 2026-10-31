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

const BenchmarkResult = @This();

const std = @import("std");
const mem = std.mem;

name: []const u8,
iterations: u64,
sample_count: usize,
total_ns: u64,

// Latency percentiles & stats (in nanoseconds)
min_ns: f64,
median_ns: f64,
mean_ns: f64,
p95_ns: f64,
p99_ns: f64,
max_ns: f64,
stddev_ns: f64,

// Throughput
ops_per_sec: f64,

// Memory metrics
allocs_per_op: f64,
frees_per_op: f64,
reallocs_per_op: f64,
bytes_per_op: f64,
peak_bytes: usize,
leaked_bytes: usize,

pub fn hasLeak(this: BenchmarkResult) bool {
    return this.leaked_bytes > 0;
}

pub fn stddevPercent(this: BenchmarkResult) f64 {
    if (this.mean_ns <= 0.0) return 0.0;
    return (this.stddev_ns / this.mean_ns) * 100.0;
}

pub fn formatDuration(ns: f64, buf: []u8) []const u8 {
    if (ns < 1000.0) {
        return mem.print(buf, "{d:.1} ns", .{ns}) catch "---";
    } else if (ns < 1_000_000.0) {
        return mem.print(buf, "{d:.2} µs", .{ns / 1000.0}) catch "---";
    } else if (ns < 1_000_000_000.0) {
        return mem.print(buf, "{d:.2} ms", .{ns / 1_000_000.0}) catch "---";
    } else {
        return mem.print(buf, "{d:.2} s", .{ns / 1_000_000_000.0}) catch "---";
    }
}

pub fn formatBytes(bytes: usize, buf: []u8) []const u8 {
    if (bytes < 1024) {
        return mem.print(buf, "{d} B", .{bytes}) catch "---";
    } else if (bytes < 1024 * 1024) {
        const kb = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return mem.print(buf, "{d:.1} KiB", .{kb}) catch "---";
    } else {
        const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return mem.print(buf, "{d:.2} MiB", .{mb}) catch "---";
    }
}

pub fn formatFloatBytes(bytes: f64, buf: []u8) []const u8 {
    if (bytes < 1024.0) {
        return mem.print(buf, "{d:.1} B", .{bytes}) catch "---";
    } else if (bytes < 1024.0 * 1024.0) {
        return mem.print(buf, "{d:.1} KiB", .{bytes / 1024.0}) catch "---";
    } else {
        return mem.print(buf, "{d:.2} MiB", .{bytes / (1024.0 * 1024.0)}) catch "---";
    }
}

pub fn formatNumber(num: f64, buf: []u8) []const u8 {
    if (num < 1_000.0) {
        return mem.print(buf, "{d:.0}", .{num}) catch "---";
    } else if (num < 1_000_000.0) {
        return mem.print(buf, "{d:.1}k", .{num / 1_000.0}) catch "---";
    } else if (num < 1_000_000_000.0) {
        return mem.print(buf, "{d:.2}M", .{num / 1_000_000.0}) catch "---";
    } else {
        return mem.print(buf, "{d:.2}B", .{num / 1_000_000_000.0}) catch "---";
    }
}

test "BenchmarkResult formatting" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    try testing.expectEqualStrings("250.0 ns", formatDuration(250.0, &buf));
    try testing.expectEqualStrings("1.50 µs", formatDuration(1500.0, &buf));
    try testing.expectEqualStrings("2.50 ms", formatDuration(2_500_000.0, &buf));
    try testing.expectEqualStrings("1.20 s", formatDuration(1_200_000_000.0, &buf));

    try testing.expectEqualStrings("512 B", formatBytes(512, &buf));
    try testing.expectEqualStrings("2.0 KiB", formatBytes(2048, &buf));
    try testing.expectEqualStrings("1.50 MiB", formatBytes(1572864, &buf));
}
