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

/// Reports CPU utilization and core frequencies using Linux procfs.
const Module = @This();

const std = @import("std");
const core = @import("core");
const Io = std.Io;
const Duration = Io.Duration;
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const fs = std.fs;
const ascii = std.ascii;

allocator: Allocator,
io: Io,
writer: *Io.Writer,
config: Config = .{},

pub const Config = struct {
    update_interval: i64 = 1,
    icon: []const u8 = "",
    text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

/// Raw CPU time sample as read from the system.
const Sample = struct {
    idle: u64,
    total: u64,
};

/// Aggregated CPU metrics calculated from samples.
const Metrics = struct {
    overall: f64,
    avg: f64,
    cores: []f64,
    freqs: []u64,
};

/// CPU frequency representation.
const Frequency = struct {
    value: f64,
    unit: []const u8,
};

pub const CPUError = error{
    UnexpectedFormat,
};

/// Initializes a new CPU module instance.
pub fn init(allocator: Allocator, io: Io, writer: *Io.Writer, config: Config) Module {
    return .{ .allocator = allocator, .io = io, .writer = writer, .config = config };
}

/// Parses a single `/proc/stat` CPU line and extracts usage counters.
fn parseLine(this: *Module, line: []const u8) !Sample {
    _ = this;

    const sp = mem.findScalar(u8, line, ' ') orelse return CPUError.UnexpectedFormat;
    var it = mem.tokenizeAny(u8, line[sp + 1 ..], " \t");

    var fields: [10]u64 = undefined;
    var idx: usize = 0;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (idx >= fields.len) break;
        fields[idx] = try fmt.parseInt(u64, tok, 10);
        idx += 1;
    }
    if (idx < 4) return CPUError.UnexpectedFormat;

    const user = fields[0];
    const nice = fields[1];
    const system = fields[2];
    const idle = fields[3];
    const iowait = if (idx > 4) fields[4] else 0;
    const irq = if (idx > 5) fields[5] else 0;
    const softirq = if (idx > 6) fields[6] else 0;
    const steal = if (idx > 7) fields[7] else 0;

    const idle_all = idle + iowait;
    const non_idle = user + nice + system + irq + softirq + steal;
    const total = idle_all + non_idle;
    return Sample{ .idle = idle_all, .total = total };
}

/// Reads a snapshot of CPU usage counters from `/proc/stat`.
fn readSnapshot(this: *Module) !struct { overall: Sample, cores: []Sample } {
    var file = try Io.Dir.openFileAbsolute(this.io, "/proc/stat", .{ .mode = .read_only });
    defer file.close(this.io);

    var buffer: [128 * 1024]u8 = undefined;
    var f_reader = file.reader(this.io, &.{});
    _ = try f_reader.interface.readSliceShort(&buffer);

    var overall: Sample = undefined;
    var have_overall = false;
    var cores_count: usize = 0;

    var lines = mem.splitScalar(u8, &buffer, '\n');
    while (lines.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!mem.startsWith(u8, line, "cpu")) break;
        if (mem.startsWith(u8, line, "cpu ")) {
            overall = try this.parseLine(line);
            have_overall = true;
        } else if (line.len >= 4 and ascii.isDigit(line[3])) cores_count += 1;
    }

    if (!have_overall) return CPUError.UnexpectedFormat;

    var cores = try this.allocator.alloc(Sample, cores_count);

    var idx: usize = 0;
    var lines2 = mem.splitScalar(u8, &buffer, '\n');
    while (lines2.next()) |raw| {
        const line = mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!mem.startsWith(u8, line, "cpu")) break;
        if (line.len >= 4 and ascii.isDigit(line[3])) {
            if (idx >= cores.len) break;
            cores[idx] = try this.parseLine(line);
            idx += 1;
        }
    }

    return .{ .overall = overall, .cores = cores };
}

/// Computes CPU usage percentage between two samples.
fn computeUsage(this: *Module, a: Sample, b: Sample) f64 {
    _ = this;

    const totald: f64 = @floatFromInt(b.total - a.total);
    const idled: f64 = @floatFromInt(b.idle - a.idle);
    if (totald <= 0) return 0.0;
    return (totald - idled) / totald * 100.0;
}

/// Reads per-CPU frequency information from `/proc/cpuinfo`.
fn readFrequencies(this: *Module) ![]u64 {
    var file = try Io.Dir.openFileAbsolute(this.io, "/proc/cpuinfo", .{ .mode = .read_only });
    defer file.close(this.io);

    var buffer: [128 * 1024]u8 = undefined;
    var f_reader = file.reader(this.io, &.{});
    _ = try f_reader.interface.readSliceShort(&buffer);

    var count: usize = 0;
    var lines1 = mem.splitScalar(u8, &buffer, '\n');
    while (lines1.next()) |raw| {
        if (mem.startsWith(u8, raw, "cpu MHz")) count += 1;
    }

    var freqs = try this.allocator.alloc(u64, count);
    if (count == 0) return freqs;

    var idx: usize = 0;
    var lines2 = mem.splitScalar(u8, &buffer, '\n');
    while (lines2.next()) |raw| {
        if (mem.startsWith(u8, raw, "cpu MHz") and idx < count) {
            var parts = mem.splitSequence(u8, raw, ":");
            _ = parts.next(); // "cpu MHz"
            if (parts.next()) |val_str| {
                const val_trim = mem.trim(u8, val_str, " \t");
                const mhz_f = try fmt.parseFloat(f64, val_trim);
                freqs[idx] = @intFromFloat(mhz_f);
                idx += 1;
            }
        }
    }

    return freqs;
}

/// Collects a single CPU usage sample by comparing two `/proc/stat` snapshots.
fn cpuUsageAllOnce(this: *Module) !Metrics {
    const a = try this.readSnapshot();
    try Io.sleep(this.io, .fromMilliseconds(200), .boot);
    const b = try this.readSnapshot();

    if (a.cores.len != b.cores.len) return CPUError.UnexpectedFormat;

    const per_core = try this.allocator.alloc(f64, a.cores.len);

    var sum: f64 = 0.0;
    for (per_core, 0..) |*val, i| {
        val.* = this.computeUsage(a.cores[i], b.cores[i]);
        sum += val.*;
    }

    const avg = if (per_core.len > 0) sum / @as(f64, @floatFromInt(per_core.len)) else 0.0;
    const freqs = try this.readFrequencies();

    return .{
        .overall = this.computeUsage(a.overall, b.overall),
        .avg = avg,
        .cores = per_core,
        .freqs = freqs,
    };
}

/// Appends a formatted per-core CPU usage and frequency line to the tooltip.
fn appendCoreLine(json_builder: *core.json, core_index: usize, usage: f64, freq_mhz: u64) !void {
    const usage_i: i64 = @intFromFloat(@round(usage));

    const is_ghz = freq_mhz >= 1000;
    const freq_val: f64 = if (is_ghz) @as(f64, @floatFromInt(freq_mhz)) / 1000.0 else @as(f64, @floatFromInt(freq_mhz));
    const unit = if (is_ghz) "GHz" else "MHz";

    const rounded = @as(i64, @intFromFloat(@round(freq_val)));
    if (freq_val != @as(f64, @floatFromInt(rounded))) {
        try json_builder.appendFmtNL("tooltip", "Core {d}: {d}% · {d:.2}{s}", .{ core_index, usage_i, freq_val, unit });
    } else {
        try json_builder.appendFmtNL("tooltip", "Core {d}: {d}% · {d}{s}", .{ core_index, usage_i, rounded, unit });
    }
}

pub fn execute(this: *Module, json_builder: *core.json) !void {
    const res = try this.cpuUsageAllOnce();

    const avg_i: i64 = @intFromFloat(@round(res.avg));

    var max_freq: f64 = 0;
    for (res.freqs) |f| {
        const f64_val: f64 = @floatFromInt(f);
        if (f64_val > max_freq) max_freq = f64_val;
    }

    const freq_val: f64 = max_freq;

    const freq = Frequency{
        .value = if (freq_val >= 1000.0) freq_val / 1000.0 else freq_val,
        .unit = if (freq_val >= 1000.0) "GHz" else "MHz",
    };

    const freq_rounded: i64 = @intFromFloat(@round(freq.value));
    const has_fraction = freq.value != @as(f64, @floatFromInt(freq_rounded));

    // Build default text
    var default_text_buf: [256]u8 = undefined;
    const default_text = if (has_fraction)
        fmt.bufPrint(&default_text_buf, "{s} {d}% · {d:.2}{s}", .{ this.config.icon, avg_i, freq.value, freq.unit }) catch ""
    else
        fmt.bufPrint(&default_text_buf, "{s} {d}% · {d}{s}", .{ this.config.icon, avg_i, freq_rounded, freq.unit }) catch "";

    // Build default tooltip
    var default_tooltip_buf: [4096]u8 = undefined;
    var tooltip_writer: Io.Writer = .fixed(&default_tooltip_buf);
    for (res.cores, 0..) |c, i| {
        const usage_i: i64 = @intFromFloat(@round(c));
        const core_freq_mhz = res.freqs[i];
        const is_ghz = core_freq_mhz >= 1000;
        const core_freq_val: f64 = if (is_ghz) @as(f64, @floatFromInt(core_freq_mhz)) / 1000.0 else @as(f64, @floatFromInt(core_freq_mhz));
        const core_unit = if (is_ghz) "GHz" else "MHz";
        const core_rounded = @as(i64, @intFromFloat(@round(core_freq_val)));

        if (i > 0) try tooltip_writer.writeByte('\n');
        if (core_freq_val != @as(f64, @floatFromInt(core_rounded))) {
            try tooltip_writer.print("Core {d}: {d}% · {d:.2}{s}", .{ i, usage_i, core_freq_val, core_unit });
        } else {
            try tooltip_writer.print("Core {d}: {d}% · {d}{s}", .{ i, usage_i, core_rounded, core_unit });
        }
    }
    const default_tooltip = default_tooltip_buf[0..tooltip_writer.end];

    // Use custom templates if provided
    if (this.config.text != null or this.config.tooltip != null) {
        var replacer = core.Replacer.init(this.allocator);
        defer replacer.deinit();

        try core.output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", this.config.icon);
        try replacer.addKeyAny("avg_usage", avg_i);
        try replacer.addKeyAny("max_frequency", if (has_fraction) freq.value else @as(f64, @floatFromInt(freq_rounded)));
        try replacer.addKey("frequency_unit", freq.unit);
        try replacer.addKeyAny("core_count", res.cores.len);

        try core.output.renderText(json_builder, &replacer, this.config.text, default_text);
        try core.output.renderTooltip(json_builder, &replacer, this.config.tooltip, default_tooltip);
    } else {
        try json_builder.set("text", default_text);
        try json_builder.set("tooltip", default_tooltip);
    }

    try json_builder.write(this.writer);
}
