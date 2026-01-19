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
const Io = std.Io;
const File = Io.File;
const process = std.process;
const fmt = std.fmt;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
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

    var waybar: Waybar = try .init(io, .{ .signal_number = 10 });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const data = try sysinfo.cpuUsageAllOnce(io, allocator);

        var max_frequency: sysinfo.Frequency = .{};
        for (data.freqs) |f| {
            if (f.value.raw > max_frequency.value.raw) max_frequency = f;
        }

        const frequency: sysinfo.Frequency = max_frequency;

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);

        try replacer.addKeyAny("usage_percentage", data.avg);
        try replacer.addKeyAny("frequency", if (frequency.value.fraction) frequency.value.raw else @as(f64, @floatFromInt(frequency.value.rounded)));
        try replacer.addKeyAny("frequency_unit", frequency.unit);
        try replacer.addKeyAny("core_count", data.cores.len);

        var tooltip_text: std.ArrayList(u8) = .empty;
        defer tooltip_text.deinit(allocator);

        for (data.cores, 0..) |c, i| {
            const usage_i: i64 = @intFromFloat(@round(c));
            const core_frequency = data.freqs[i];

            try replacer.addKeyAny("core_index", i);
            try replacer.addKeyAny("core_usage_percentage", usage_i);
            try replacer.addKeyAny("core_frequency", if (core_frequency.value.fraction) core_frequency.value.raw else @as(f64, @floatFromInt(core_frequency.value.rounded)));
            try replacer.addKeyAny("core_frequency_unit", core_frequency.unit);

            const line = try replacer.render(config.tooltip);
            if (tooltip_text.items.len > 0) try tooltip_text.append(allocator, '\n');
            try tooltip_text.appendSlice(allocator, line);
        }

        try json.set("tooltip", tooltip_text.items);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.update();
    }
}
