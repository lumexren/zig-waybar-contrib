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

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const zon = std.zon;
const Allocator = mem.Allocator;

const runner = @import("../runner.zig");
const reporter_mod = @import("../reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const BENCHMARKS = [_][]const u8{
    "config_zon_parse_cpu",
    "config_zon_parse_memory",
    "config_zon_parse_custom",
};

pub const CpuConfig = struct {
    update_interval: i64 = 1,
    one_indexed: bool = false,
    warning_threshold: ?f64 = 70.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {usage_percentage:'%'} {dot} {frequency:2:frequency_unit}",
    tooltip: []const u8 = "Core {core_index}: {core_usage_percentage:'%'} {dot} {core_frequency:2:core_frequency_unit}",
};

pub const MemoryConfig = struct {
    update_interval: i64 = 1,
    warning_threshold: ?f64 = 75.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage:'%'} {dot} {total_usage:.2}",
    tooltip: []const u8 = "Physical Memory{nl}Total {dot} {physical_total:.2:nl}Used {dot} {physical_used:.2:nl}",
};

pub const CustomConfig = struct {
    name: []const u8 = "custom",
    interval: u32 = 5,
    enabled: bool = true,
    thresholds: struct {
        low: f64 = 20.0,
        medium: f64 = 50.0,
        high: f64 = 80.0,
    } = .{},
    format: []const u8 = "{icon} {value:.1}%",
    icons: struct {
        low: []const u8 = "󰾆",
        medium: []const u8 = "󰾅",
        high: []const u8 = "󰓅",
    } = .{},
};

const SAMPLE_CPU_ZON =
    \\.{
    \\    .update_interval = 2,
    \\    .one_indexed = true,
    \\    .warning_threshold = 65.0,
    \\    .critical_threshold = 85.0,
    \\    .icon = "󰍛",
    \\    .text = "{icon} {usage_percentage:'%'} ({frequency:2:frequency_unit})",
    \\    .tooltip = "Core {core_index}: {core_usage_percentage:'%'} @ {core_frequency:2:core_frequency_unit}",
    \\}
;

const SAMPLE_MEMORY_ZON =
    \\.{
    \\    .update_interval = 1,
    \\    .warning_threshold = 80.0,
    \\    .critical_threshold = 95.0,
    \\    .icon = "",
    \\    .text = "{icon} {percentage:'%'} • {physical_used:.2}",
    \\    .tooltip = "Total: {physical_total:.2}\nUsed: {physical_used:.2}\nFree: {physical_free:.2}",
    \\}
;

const SAMPLE_CUSTOM_ZON =
    \\.{
    \\    .name = "battery-monitor",
    \\    .interval = 10,
    \\    .enabled = true,
    \\    .thresholds = .{
    \\        .low = 15.0,
    \\        .medium = 40.0,
    \\        .high = 90.0,
    \\    },
    \\    .format = "{icon} {value:.2}%",
    \\    .icons = .{
    \\        .low = "󰂎",
    \\        .medium = "󰁽",
    \\        .high = "󰂅",
    \\    },
    \\}
;

fn benchConfigParseCpu(allocator: Allocator, _: void) !void {
    var arena: heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var diag: zon.parse.Diagnostics = undefined;
    const cfg = try zon.parse.fromSlice(CpuConfig, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = SAMPLE_CPU_ZON,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    mem.doNotOptimizeAway(cfg);
}

fn benchConfigParseMemory(allocator: Allocator, _: void) !void {
    var arena: heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var diag: zon.parse.Diagnostics = undefined;
    const cfg = try zon.parse.fromSlice(MemoryConfig, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = SAMPLE_MEMORY_ZON,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    mem.doNotOptimizeAway(cfg);
}

fn benchConfigParseCustom(allocator: Allocator, _: void) !void {
    var arena: heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    var diag: zon.parse.Diagnostics = undefined;
    const cfg = try zon.parse.fromSlice(CustomConfig, .{
        .gpa = allocator,
        .arena = arena.allocator(),
        .source = SAMPLE_CUSTOM_ZON,
        .diagnostics = &diag,
        .ignore_unknown_fields = true,
    });
    mem.doNotOptimizeAway(cfg);
}

fn shouldRun(name: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return mem.find(u8, name, f) != null or mem.eql(u8, f, "config");
}

pub fn runBenchmarks(
    allocator: Allocator,
    reporter: *Reporter,
    writer: anytype,
    options: runner.BenchmarkOptions,
    filter: ?[]const u8,
) !void {
    if (shouldRun("config_zon_parse_cpu", filter)) {
        const r = try runner.run(allocator, "config_zon_parse_cpu", options, benchConfigParseCpu, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("config_zon_parse_memory", filter)) {
        const r = try runner.run(allocator, "config_zon_parse_memory", options, benchConfigParseMemory, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("config_zon_parse_custom", filter)) {
        const r = try runner.run(allocator, "config_zon_parse_custom", options, benchConfigParseCustom, {});
        try reporter.report(writer, r);
    }
}
