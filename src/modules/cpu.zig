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

const CPU = @import("sysinfo").CPU;

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
const Replacer = utils.Replacer;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 13,
    one_indexed: bool = false,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {usage_percentage:'%'} {dot} {frequency:2:frequency_unit}",
    tooltip: []const u8 = "Core {core_index}: {core_usage_percentage:'%'} {dot} {core_frequency:2:core_frequency_unit}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("cpu", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var cpu: CPU = .init(io, gpa);
    defer cpu.deinit();

    while (true) : (try io.sleep(.fromSeconds(data.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        try cpu.update();

        var max_frequency: CPU.Frequency = .{};
        var min_frequency: CPU.Frequency = .{ .value = .{ .raw = math.floatMax(f64) } };
        var global_freq_min: CPU.Frequency = .{ .value = .{ .raw = math.floatMax(f64) } };
        var global_freq_max: CPU.Frequency = .{};

        for (cpu.cores) |core| {
            if (core.frequency.current.value.raw > max_frequency.value.raw) max_frequency = core.frequency.current;
            if (core.frequency.current.value.raw < min_frequency.value.raw) min_frequency = core.frequency.current;
            if (core.frequency.min.value.raw < global_freq_min.value.raw) global_freq_min = core.frequency.min;
            if (core.frequency.max.value.raw > global_freq_max.value.raw) global_freq_max = core.frequency.max;
        }

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);

        try replacer.addKeyAny("usage_percentage", @as(i64, @intFromFloat(@round(cpu.avg))));
        try replacer.addKeyAny("frequency", if (max_frequency.value.fraction) max_frequency.value.raw else @as(f64, @floatFromInt(max_frequency.value.rounded)));
        try replacer.addKeyAny("frequency_unit", max_frequency.unit);
        try replacer.addKeyAny("frequency_min", if (global_freq_min.value.fraction) global_freq_min.value.raw else @as(f64, @floatFromInt(global_freq_min.value.rounded)));
        try replacer.addKeyAny("frequency_min_unit", global_freq_min.unit);
        try replacer.addKeyAny("frequency_max", if (global_freq_max.value.fraction) global_freq_max.value.raw else @as(f64, @floatFromInt(global_freq_max.value.rounded)));
        try replacer.addKeyAny("frequency_max_unit", global_freq_max.unit);
        try replacer.addKeyAny("core_count", cpu.cores.len);

        var tooltip_text: ArrayList(u8) = .empty;
        defer tooltip_text.deinit(gpa);

        for (cpu.cores, 0..) |core, i| {
            const freq_current = core.frequency.current;
            const freq_min = core.frequency.min;
            const freq_max = core.frequency.max;

            try replacer.addKeyAny("core_index", if (data.one_indexed) i + 1 else i);
            try replacer.addKeyAny("core_usage_percentage", @as(i64, @intFromFloat(@round(core.usage))));
            try replacer.addKeyAny("core_frequency", if (freq_current.value.fraction) freq_current.value.raw else @as(f64, @floatFromInt(freq_current.value.rounded)));
            try replacer.addKeyAny("core_frequency_unit", freq_current.unit);
            try replacer.addKeyAny("core_frequency_min", if (freq_min.value.fraction) freq_min.value.raw else @as(f64, @floatFromInt(freq_min.value.rounded)));
            try replacer.addKeyAny("core_frequency_min_unit", freq_min.unit);
            try replacer.addKeyAny("core_frequency_max", if (freq_max.value.fraction) freq_max.value.raw else @as(f64, @floatFromInt(freq_max.value.rounded)));
            try replacer.addKeyAny("core_frequency_max_unit", freq_max.unit);

            const line = try replacer.render(data.tooltip);
            defer replacer.free(line);

            if (tooltip_text.items.len > 0) try tooltip_text.append(gpa, '\n');
            try tooltip_text.appendSlice(gpa, line);
        }

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_text.items);

        try json.write(stdout);
        try stdout.flush();
    }
}
