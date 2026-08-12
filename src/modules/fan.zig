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

const Fan = @import("sysinfo").Fan;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;

pub const ModuleConfig = struct {
    update_interval: i64 = 2,
    signal_number: u8 = 15,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {total_fans}",
    tooltip: []const u8 = "{name}: {speed} RPM",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("fan", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var fans: ArrayList(Fan.FanInfo) = .empty;

    var fan: Fan = .init(io, gpa, &fans);
    defer fan.deinit();

    while (true) : (try io.sleep(.fromSeconds(data.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();
        defer fan.clear();

        try fan.scan();

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKeyAny("total_fans", fans.items.len);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        try json.set("text", text_line);

        var tooltip_text: ArrayList(u8) = .empty;
        defer tooltip_text.deinit(replacer.allocator);

        for (fan.fans.items) |f| {
            try replacer.addKey("name", f.name);
            try replacer.addKeyAny("speed", f.speed);

            const line = try replacer.render(data.tooltip);
            defer replacer.free(line);

            if (tooltip_text.items.len > 0) try tooltip_text.append(replacer.allocator, '\n');
            try tooltip_text.appendSlice(replacer.allocator, line);
        }

        try json.set("tooltip", tooltip_text.items);

        try json.write(stdout);
        try stdout.flush();
    }
}
