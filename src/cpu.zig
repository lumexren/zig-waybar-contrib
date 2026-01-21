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

const Module = @This();

const sysinfo = @import("sysinfo").cpu;

const std = @import("std");
const utils = @import("utils");
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = Io.File;
const process = std.process;
const fmt = std.fmt;
const os = std.os;
const math = std.math;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 10,
    icon: []const u8 = "",
    text: []const u8 = "{icon} {usage_percentage}% {dot} {frequency:2}{frequency_unit}",
    tooltip: []const u8 = "Core {core_index}: {core_usage_percentage}% {dot} {core_frequency:2}{core_frequency_unit}",
};

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("cpu", ModuleConfig);

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const data = try sysinfo.cpuUsageAllOnce(io, allocator);

        // Find min/max current frequency across all cores
        var max_frequency: sysinfo.Frequency = .{};
        var min_frequency: sysinfo.Frequency = .{ .value = .{ .raw = math.floatMax(f64) } };
        var global_freq_min: sysinfo.Frequency = .{ .value = .{ .raw = math.floatMax(f64) } };
        var global_freq_max: sysinfo.Frequency = .{};

        for (data.cores) |core| {
            if (core.frequency.current.value.raw > max_frequency.value.raw) max_frequency = core.frequency.current;
            if (core.frequency.current.value.raw < min_frequency.value.raw) min_frequency = core.frequency.current;
            if (core.frequency.min.value.raw < global_freq_min.value.raw) global_freq_min = core.frequency.min;
            if (core.frequency.max.value.raw > global_freq_max.value.raw) global_freq_max = core.frequency.max;
        }

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);

        try replacer.addKeyAny("usage_percentage", @as(i64, @intFromFloat(@round(data.avg))));
        try replacer.addKeyAny("frequency", if (max_frequency.value.fraction) max_frequency.value.raw else @as(f64, @floatFromInt(max_frequency.value.rounded)));
        try replacer.addKeyAny("frequency_unit", max_frequency.unit);
        try replacer.addKeyAny("frequency_min", if (global_freq_min.value.fraction) global_freq_min.value.raw else @as(f64, @floatFromInt(global_freq_min.value.rounded)));
        try replacer.addKeyAny("frequency_min_unit", global_freq_min.unit);
        try replacer.addKeyAny("frequency_max", if (global_freq_max.value.fraction) global_freq_max.value.raw else @as(f64, @floatFromInt(global_freq_max.value.rounded)));
        try replacer.addKeyAny("frequency_max_unit", global_freq_max.unit);
        try replacer.addKeyAny("core_count", data.cores.len);

        var tooltip_text: ArrayList(u8) = .empty;
        defer tooltip_text.deinit(allocator);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        for (data.cores, 0..) |core, i| {
            const usage_i: i64 = @intFromFloat(@round(core.usage));
            const freq_current = core.frequency.current;
            const freq_min = core.frequency.min;
            const freq_max = core.frequency.max;

            try replacer.addKeyAny("core_index", i);
            try replacer.addKeyAny("core_usage_percentage", usage_i);
            try replacer.addKeyAny("core_frequency", if (freq_current.value.fraction) freq_current.value.raw else @as(f64, @floatFromInt(freq_current.value.rounded)));
            try replacer.addKeyAny("core_frequency_unit", freq_current.unit);
            try replacer.addKeyAny("core_frequency_min", if (freq_min.value.fraction) freq_min.value.raw else @as(f64, @floatFromInt(freq_min.value.rounded)));
            try replacer.addKeyAny("core_frequency_min_unit", freq_min.unit);
            try replacer.addKeyAny("core_frequency_max", if (freq_max.value.fraction) freq_max.value.raw else @as(f64, @floatFromInt(freq_max.value.rounded)));
            try replacer.addKeyAny("core_frequency_max_unit", freq_max.unit);

            const line = try replacer.render(config.tooltip);
            if (tooltip_text.items.len > 0) try tooltip_text.append(allocator, '\n');
            try tooltip_text.appendSlice(allocator, line);
        }

        try json.set("tooltip", tooltip_text.items);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
