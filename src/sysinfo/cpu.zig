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

const CPU = @This();

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const math = std.math;
const ascii = std.ascii;
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const MAX_CORES: usize = 1024;
const STAT_BUFFER_SIZE: usize = 16 * 1024;
const CPUINFO_BUFFER_SIZE: usize = 64 * 1024;

pub const CPUError = error{
    UnexpectedFormat,
    CoreCountChanged,
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

io: Io,
allocator: Allocator,
// Historical counters used for delta tracking
prev_overall: Sample = .{ .idle = 0, .total = 0 },
prev_cores: []Sample = &.{},
// Public metrics read by the caller after calling update()
overall: f64 = 0.0,
avg: f64 = 0.0,
cores: []CoreInfo = &.{},
// Internal reusable scratch buffer to avoid heap allocations during parsing
scratch_samples: ArrayListUnmanaged(Sample) = .empty,

pub fn init(io: Io, allocator: Allocator) CPU {
    return .{ .io = io, .allocator = allocator };
}

pub fn deinit(this: *CPU) void {
    this.allocator.free(this.prev_cores);
    this.allocator.free(this.cores);
    this.scratch_samples.deinit(this.allocator);
}

/// Updates CPU usage metrics and frequencies.
/// On the very first run, it establishes a quick baseline snapshot automatically.
pub fn update(this: *CPU) !void {
    var curr_overall: Sample = undefined;

    if (this.prev_cores.len == 0) {
        try this.captureSnapshot(&this.prev_overall);

        const core_count = this.scratch_samples.items.len;

        this.prev_cores = try this.allocator.alloc(Sample, core_count);
        errdefer {
            this.allocator.free(this.prev_cores);
            this.prev_cores = &.{};
        }

        @memcpy(this.prev_cores, this.scratch_samples.items);

        this.cores = try this.allocator.alloc(CoreInfo, core_count);
        errdefer {
            this.allocator.free(this.cores);
            this.cores = &.{};
        }

        @memset(this.cores, .{});

        try this.io.sleep(.fromMilliseconds(100), .boot);
    }

    try this.captureSnapshot(&curr_overall);

    if (this.scratch_samples.items.len != this.prev_cores.len) {
        return CPUError.CoreCountChanged;
    }

    this.overall = computeUsage(this.prev_overall, curr_overall);

    var sum: f64 = 0.0;
    for (this.prev_cores, this.scratch_samples.items, 0..) |core_a, core_b, i| {
        const usage = computeUsage(core_a, core_b);
        this.cores[i].usage = usage;
        sum += usage;
    }

    this.avg = if (this.cores.len > 0) sum / @as(f64, @floatFromInt(this.cores.len)) else 0.0;

    this.updateFrequencies();

    this.prev_overall = curr_overall;
    @memcpy(this.prev_cores, this.scratch_samples.items);
}

fn captureSnapshot(this: *CPU, overall: *Sample) !void {
    this.scratch_samples.clearRetainingCapacity();

    var file = try Dir.openFileAbsolute(this.io, "/proc/stat", .{ .mode = .read_only });
    defer file.close(this.io);

    var buffer: [STAT_BUFFER_SIZE]u8 = undefined;
    var reader = file.reader(this.io, &.{});
    const bytes_read = try reader.interface.readSliceShort(&buffer);

    var have_overall = false;
    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');
    while (lines.next()) |raw| {
        const line = mem.trimStart(u8, raw, " \t");
        if (!mem.startsWith(u8, line, "cpu")) break;
        if (line.len > 3 and (line[3] == ' ' or line[3] == '\t')) {
            overall.* = try parseLine(line);
            have_overall = true;
        } else if (line.len > 3 and ascii.isDigit(line[3])) {
            try this.scratch_samples.append(this.allocator, try parseLine(line));
        }
    }

    if (!have_overall) return CPUError.UnexpectedFormat;
}

fn updateFrequencies(this: *CPU) void {
    var path_buf: [128]u8 = undefined;
    for (this.cores, 0..) |*core, i| {
        core.frequency = .{
            .min = readFrequencyFromSysfs(this.io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_min_freq", .{i}) catch "") orelse .{},
            .max = readFrequencyFromSysfs(this.io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_max_freq", .{i}) catch "") orelse .{},
            .current = readFrequencyFromSysfs(this.io, fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_cur_freq", .{i}) catch "") orelse .{},
        };
    }
}

pub inline fn parseLine(line: []const u8) CPUError!Sample {
    var it = mem.tokenizeScalar(u8, line, ' ');
    _ = it.next() orelse return CPUError.UnexpectedFormat;

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

pub inline fn computeUsage(a: Sample, b: Sample) f64 {
    if (b.total <= a.total or b.idle < a.idle) return 0.0;
    const totald = b.total - a.total;
    const idled = b.idle - a.idle;
    if (idled > totald) return 0.0;

    return (@as(f64, @floatFromInt(totald)) - @as(f64, @floatFromInt(idled))) / @as(f64, @floatFromInt(totald)) * 100.0;
}

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

fn readFrequencyFromSysfs(io: Io, path: []const u8) ?Frequency {
    var file = Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return null;
    defer file.close(io);

    var buf: [32]u8 = undefined;
    var reader = file.reader(io, &.{});
    const bytes_read = reader.interface.readSliceShort(&buf) catch return null;
    const line = mem.trim(u8, buf[0..bytes_read], " \t\n\r");

    const mhz: f64 = @as(f64, @floatFromInt(fmt.parseInt(u64, line, 10) catch return null)) * 0.001;
    return calculateFrequency(mhz);
}


// Tests
test "cpu lifecycle and update integration" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    // 1. Initialize the stateful CPU container
    var cpu: CPU = .init(allocator);

    // 2. Ensure everything deallocates cleanly.
    // This entirely replaces the old "cpu usage leak" verification.
    defer cpu.deinit();

    // First update handles internal allocations and primes the baseline counters
    cpu.update(io) catch |err| {
        if (err == error.FileNotFound) return; // Guard for non-Linux platforms
        return err;
    };

    // Confirm that backing slices were allocated properly based on the host system
    try std.testing.expect(cpu.cores.len > 0);
    try std.testing.expect(cpu.prev_cores.len == cpu.cores.len);

    // Sleep briefly to accumulate a tiny amount of CPU jitter for delta testing
    try io.sleep(.fromMilliseconds(50), .boot);

    // Second update cycles counters and calculates the real deltas
    try cpu.update(io);

    // Smoke check metric boundaries
    try std.testing.expect(cpu.overall >= 0.0 and cpu.overall <= 100.0);
    try std.testing.expect(cpu.avg >= 0.0 and cpu.avg <= 100.0);

    for (cpu.cores) |core| {
        try std.testing.expect(core.usage >= 0.0 and core.usage <= 100.0);
        try std.testing.expect(core.frequency.current.value.raw >= 0.0);
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
    const s3 = Sample{ .idle = 50, .total = 100 };

    // 0 -> 1: total delta 100, idle delta 50. Usage = (100-50)/100 = 50%
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s0, s1), 0.001);

    // 1 -> 2: total delta 100, idle delta 50. Usage = 50%
    try std.testing.expectApproxEqAbs(@as(f64, 50.0), computeUsage(s1, s2), 0.001);

    // No time passed (total == 0)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s3), 0.001);

    // 100% usage: total increases, idle stays same
    const s_busy = Sample{ .idle = 50, .total = 200 };
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), computeUsage(s1, s_busy), 0.001);

    // 0% usage: total increases, idle increases same amount
    const s_idle = Sample{ .idle = 150, .total = 200 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle), 0.001);

    // Counter wrap-around: b.total < a.total
    const s_wrap = Sample{ .idle = 10, .total = 50 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_wrap), 0.001);

    // Idle counter decreases: b.idle < a.idle
    const s_idle_dec = Sample{ .idle = 30, .total = 150 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), computeUsage(s1, s_idle_dec), 0.001);
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
    try std.testing.expectEqual(@as(i64, 3), f2.value.rounded);
    try std.testing.expectEqual(true, f2.value.fraction);

    // 3000 MHz -> 3 GHz
    const f3 = calculateFrequency(3000.0);
    try std.testing.expectEqualStrings("GHz", f3.unit);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), f3.value.raw, 0.001);
    try std.testing.expectEqual(@as(i64, 3), f3.value.rounded);
    try std.testing.expectEqual(false, f3.value.fraction);

    // Noise suppression check
    const f4 = calculateFrequency(800.0000001);
    try std.testing.expectEqualStrings("MHz", f4.unit);
    try std.testing.expectEqual(false, f4.value.fraction);
}
