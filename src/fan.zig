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

const sysinfo = @import("sysinfo").fan;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 5,
    icon: []const u8 = "",
    text: []const u8 = "{icon} {total_fans}",
    tooltip: []const u8 = "{name}: {speed} RPM",
};

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("fan", ModuleConfig);

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = 10 });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        var fans: ArrayList(sysinfo.FanInfo) = .empty;
        defer fans.deinit(allocator);

        try sysinfo.scanHwmonFans(io, allocator, &fans, "/sys/class/hwmon");

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);
        try replacer.addKeyAny("total_fans", fans.items.len);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        var tooltip_text: ArrayList(u8) = .empty;
        defer tooltip_text.deinit(allocator);

        for (fans.items) |fan| {
            try replacer.addKey("name", fan.name);
            try replacer.addKeyAny("speed", fan.speed);

            const line = try replacer.render(config.tooltip);
            if (tooltip_text.items.len > 0) try tooltip_text.append(allocator, '\n');
            try tooltip_text.appendSlice(allocator, line);
        }

        try json.set("tooltip", tooltip_text.items);

        try json.write(stdout);
        try stdout.flush();

        try waybar.update();
    }
}
