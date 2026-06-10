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

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;
const ascii = std.ascii;
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayListUnmanaged;

pub const CPUError = error{
    UnexpectedFormat,
};

/// Raw CPU time sample as read from the system.
pub const Sample = struct {
    idle: u64,
    total: u64,
};

/// Result type for readSnapshot to avoid struct creation overhead.
pub const SnapshotResult = struct {
    overall: Sample,
    cores: []Sample,
};

/// Combined per-core CPU information.
pub const CoreInfo = struct {
    usage: f64 = 0.0,
    frequency: FrequencyRange = .{},
};

/// Aggregated CPU metrics calculated from samples.
pub const Metrics = struct {
    overall: f64,
    avg: f64,
    cores: []CoreInfo,
};

/// CPU frequency range (min, max, current).
pub const FrequencyRange = struct {
    min: Frequency = .{},
    max: Frequency = .{},
    current: Frequency = .{},
};

/// CPU frequency representation.
pub const Frequency = struct {
    value: FrequencyValue = .{},
    unit: []const u8 = "MHz",
};

pub const FrequencyValue = struct {
    raw: f64 = 0.0,
    rounded: i64 = 0,
    fraction: bool = false,
};

// Maximum expected cores (pre-allocate to avoid reallocations)
const MAX_CORES: usize = 256;

// Optimized buffer sizes based on typical file sizes
const STAT_BUFFER_SIZE: usize = 16 * 1024; // /proc/stat is typically small
const CPUINFO_BUFFER_SIZE: usize = 64 * 1024; // /proc/cpuinfo can be larger

/// Parses a single `/proc/stat` CPU line and extracts usage counters.
pub inline fn parseLine(line: []const u8) CPUError!Sample {
    var it = mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return CPUError.UnexpectedFormat; // Skip prefix (e.g. "cpu" or "cpu0")

    var fields: [8]u64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var idx: usize = 0;
    while (it.next()) |tok| : (idx += 1) {
        if (idx >= 8) break;
        fields[idx] = fmt.parseInt(u64, tok, 10) catch return CPUError.UnexpectedFormat;
    }

    if (idx < 4) return CPUError.UnexpectedFormat;

    const idle_all = fields[3] + fields[4];
    const non_idle = fields[0] + fields[1] + fields[2] + fields[5] + fields[6] + fields[7];

    return .{ .idle = idle_all, .total = idle_all + non_idle };
}

/// Reads a snapshot of CPU usage counters from `/proc/stat`.
pub fn readSnapshot(io: Io, allocator: Allocator) !SnapshotResult {
    var file = try Dir.openFileAbsolute(io, "/proc/stat", .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [STAT_BUFFER_SIZE]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = try reader.interface.readSliceShort(&buffer);

    var overall: Sample = undefined;
    var have_overall = false;

    var cores_list: ArrayList(Sample) = .empty;
    errdefer cores_list.deinit(allocator);
    try cores_list.ensureTotalCapacity(allocator, MAX_CORES);

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');
    while (lines.next()) |raw| {
        const line = mem.trimStart(u8, raw, " \t");
        if (!mem.startsWith(u8, line, "cpu")) break;
        if (line.len > 3 and (line[3] == ' ' or line[3] == '\t')) {
            overall = try parseLine(line);
            have_overall = true;
        } else if (line.len > 3 and ascii.isDigit(line[3])) try cores_list.append(allocator, try parseLine(line));
    }

    if (!have_overall) return CPUError.UnexpectedFormat;

    return .{
        .overall = overall,
        .cores = try cores_list.toOwnedSlice(allocator),
    };
}

/// Computes CPU usage percentage between two samples.
/// Handles counter wrap-around by returning 0.0 if counters decrease.
pub inline fn computeUsage(a: Sample, b: Sample) f64 {
    // Guard against counter wrap-around or CPU hotplug scenarios
    if (b.total <= a.total or b.idle < a.idle) return 0.0;

    const totald = b.total - a.total;
    const idled = b.idle - a.idle;

    if (idled > totald) return 0.0;

    const total_f: f64 = @floatFromInt(totald);
    const idle_f: f64 = @floatFromInt(idled);

    return (total_f - idle_f) / total_f * 100.0;
}

/// Reads per-CPU frequency information from `/proc/cpuinfo`.
pub fn readFrequencies(io: Io, allocator: Allocator) ![]Frequency {
    var file = try Dir.openFileAbsolute(io, "/proc/cpuinfo", .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [CPUINFO_BUFFER_SIZE]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = try reader.interface.readSliceShort(&buffer);

    var freqs_list: ArrayList(Frequency) = .empty;
    errdefer freqs_list.deinit(allocator);
    try freqs_list.ensureTotalCapacity(allocator, MAX_CORES);

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');
    while (lines.next()) |raw| {
        const line = mem.trimStart(u8, raw, " \t");
        if (!mem.startsWith(u8, line, "cpu MHz")) continue;

        if (mem.findScalar(u8, line, ':')) |colon_pos| {
            if (colon_pos + 1 < line.len) {
                const val_str = mem.trim(u8, line[colon_pos + 1 ..], " \t\r");
                if (fmt.parseFloat(f64, val_str)) |mhz| {
                    try freqs_list.append(allocator, calculateFrequency(mhz));
                } else |_| {
                    continue;
                }
            }
        }
    }

    return try freqs_list.toOwnedSlice(allocator);
}

/// Calculates frequency with unit conversion.
pub inline fn calculateFrequency(mhz: f64) Frequency {
    const is_ghz = mhz >= 1000.0;
    const value = if (is_ghz) mhz * 0.001 else mhz;
    const value_rounded: i64 = @intFromFloat(@round(value));
    const rounded_f: f64 = @floatFromInt(value_rounded);

    return .{
        .value = .{
            .raw = value,
            .rounded = value_rounded,
            .fraction = @abs(value - rounded_f) > 0.001,
        },
        .unit = if (is_ghz) "GHz" else "MHz",
    };
}

/// Reads a frequency value from a sysfs file (value is in kHz).
fn readFrequencyFromSysfs(io: Io, path: []const u8) ?Frequency {
    var file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buf) catch return null;
    const line = mem.trim(u8, buf[0..bytes_read], " \t\n\r");

    const khz = fmt.parseInt(u64, line, 10) catch return null;
    const mhz: f64 = @as(f64, @floatFromInt(khz)) * 0.001;
    return calculateFrequency(mhz);
}

/// Reads frequency ranges (min, max, current) for all CPU cores from sysfs.
pub fn readFrequencyRanges(io: Io, allocator: Allocator, core_count: usize) ![]FrequencyRange {
    var ranges = try allocator.alloc(FrequencyRange, core_count);
    errdefer allocator.free(ranges);

    var path_buf: [128]u8 = undefined;
    for (0..core_count) |i| {
        ranges[i] = .{
            .min = readFrequencyFromSysfs(io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_min_freq", .{i}) catch "") orelse .{},
            .max = readFrequencyFromSysfs(io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_max_freq", .{i}) catch "") orelse .{},
            .current = readFrequencyFromSysfs(io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq", .{i}) catch "") orelse .{},
        };
    }

    return ranges;
}

/// Collects a single CPU usage sample by comparing two `/proc/stat` snapshots.
pub fn cpuUsageAllOnce(io: Io, allocator: Allocator) !Metrics {
    const a = try readSnapshot(io, allocator);
    defer allocator.free(a.cores);

    try io.sleep(.fromMilliseconds(200), .boot);

    const b = try readSnapshot(io, allocator);
    defer allocator.free(b.cores);

    if (a.cores.len != b.cores.len) return CPUError.UnexpectedFormat;

    const core_count = a.cores.len;
    const freq_ranges = try readFrequencyRanges(io, allocator, core_count);
    defer allocator.free(freq_ranges);

    const cores = try allocator.alloc(CoreInfo, core_count);
    errdefer allocator.free(cores);

    var sum: f64 = 0.0;
    for (a.cores, b.cores, 0..) |core_a, core_b, i| {
        const usage = computeUsage(core_a, core_b);
        cores[i] = .{
            .usage = usage,
            .frequency = freq_ranges[i],
        };
        sum += usage;
    }

    const avg: f64 = if (core_count > 0) sum / @as(f64, @floatFromInt(core_count)) else 0.0;

    return .{
        .overall = computeUsage(a.overall, b.overall),
        .avg = avg,
        .cores = cores,
    };
}

test "cpu usage leak" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    const metrics_or_err = cpuUsageAllOnce(io, allocator);
    if (metrics_or_err) |metrics| {
        defer allocator.free(metrics.cores);
    } else |err| {
        if (err == error.FileNotFound) return;
        return err;
    }
}

test "parseLine" {
    // Valid cpu line
    const line = "cpu  100 200 300 400 500 600 700 800";
    const sample = try parseLine(line);
    // idle = idle(400) + iowait(500) = 900
    // non_idle = user(100) + nice(200) + system(300) + irq(600) + softirq(700) + steal(800) = 2700
    // total = 3600
    try std.testing.expectEqual(@as(u64, 900), sample.idle);
    try std.testing.expectEqual(@as(u64, 3600), sample.total);

    // Valid core line (cpu0) - same format
    const line2 = "cpu0 10 20 30 40 50 60 70 80";
    const sample2 = try parseLine(line2);
    // idle=40+50=90; non_idle=10+20+30+60+70+80=270; total=360
    try std.testing.expectEqual(@as(u64, 90), sample2.idle);
    try std.testing.expectEqual(@as(u64, 360), sample2.total);

    // Missing fields (less than 4)
    const line3 = "cpu  10 20 30";
    try std.testing.expectError(CPUError.UnexpectedFormat, parseLine(line3));

    // Bad format (non-integer)
    const line4 = "cpu  10 20 abc 40";
    try std.testing.expectError(CPUError.UnexpectedFormat, parseLine(line4));
}

test "computeUsage" {
    const s0 = Sample{ .idle = 0, .total = 0 };
    const s1 = Sample{ .idle = 50, .total = 100 };
    const s2 = Sample{ .idle = 100, .total = 200 };
    const s3 = Sample{ .idle = 50, .total = 100 }; // Same as s1 (no time passing)

    // 0 -> 1: total delta 100, idle delta 50. Usage = (100-50)/100 = 50%
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s0, s1), 0.001);

    // 1 -> 2: total delta 100, idle delta 50. Usage = 50%
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s1, s2), 0.001);

    // No time passed (total == 0)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s3), 0.001);

    // 100% usage: total increases, idle stays same
    const s_busy = Sample{ .idle = 50, .total = 200 }; // +100 total, +0 idle
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), computeUsage(s1, s_busy), 0.001);

    // 0% usage: total increases, idle increases same amount
    const s_idle = Sample{ .idle = 150, .total = 200 }; // +100 total, +100 idle
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle), 0.001);

    // Counter wrap-around: b.total < a.total (CPU hotplug or counter reset)
    const s_wrap = Sample{ .idle = 10, .total = 50 }; // Lower than s1
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_wrap), 0.001);

    // Idle counter decreases: b.idle < a.idle
    const s_idle_dec = Sample{ .idle = 30, .total = 150 }; // total up, idle down
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle_dec), 0.001);
}

test "readSnapshot smoke test" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    const result = readSnapshot(io, allocator) catch |err| {
        if (err == error.FileNotFound) return; // Not on linux or proc fs not mounted
        return err;
    };
    defer allocator.free(result.cores);

    // Smoke check
    if (result.overall.total > 0) {
        try std.testing.expect(result.overall.total >= result.overall.idle);
    }
}

test "readFrequencies smoke test" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    const freqs = readFrequencies(io, allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer allocator.free(freqs);

    // Just verify we can iterate them
    for (freqs) |f| {
        try std.testing.expect(f.value.raw >= 0.0);
    }
}

test "calculateFrequency" {
    // 800 MHz -> 800 MHz
    const f1 = calculateFrequency(800.0);
    try std.testing.expectEqualStrings("MHz", f1.unit);
    try std.testing.expectApproxEqAbs(@as(f64, 800.0), f1.value.raw, 0.001);
    try std.testing.expectEqual(@as(i64, 800), f1.value.rounded);
    try std.testing.expectEqual(false, f1.value.fraction);

    // 2500 MHz -> 2.5 GHz
    const f2 = calculateFrequency(2500.0);
    try std.testing.expectEqualStrings("GHz", f2.unit);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), f2.value.raw, 0.001);
    try std.testing.expectEqual(@as(i64, 3), f2.value.rounded); // rounds to nearest integer
    try std.testing.expectEqual(true, f2.value.fraction); // 2.5 != 3.0

    // 3000 MHz -> 3 GHz
    const f3 = calculateFrequency(3000.0);
    try std.testing.expectEqualStrings("GHz", f3.unit);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), f3.value.raw, 0.001);
    try std.testing.expectEqual(@as(i64, 3), f3.value.rounded);
    try std.testing.expectEqual(false, f3.value.fraction);

    // 2500.0000001 MHz -> 2.5 GHz (noise suppression check)
    // 2.5 GHz value. 2.5 vs 3 rounded. Fraction IS true.
    // Wait, let's check strict noise like 800.0000001 MHz -> 800 MHz
    const f4 = calculateFrequency(800.0000001);
    try std.testing.expectEqualStrings("MHz", f4.unit);
    try std.testing.expectEqual(false, f4.value.fraction); // Should match 800.0 within epsilon
}
