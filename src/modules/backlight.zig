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

const Backlight = @import("sysinfo").Backlight;

const plume = @import("plume");
const Connection = plume.Connection;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 10,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage:'%'}",
    tooltip: []const u8 = "Brightness: {percentage:'%':nl}Device: {name}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("backlight", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var connection: Connection = try .init(io, gpa, init.environ_map, .System);
    defer connection.close();

    var backlight: Backlight = try .init(io, gpa, &connection);
    defer backlight.deinit();

    while (true) : (try io.sleep(.fromSeconds(data.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        var info = backlight.getDefaultBacklight() catch |err| {
            try json.set("text", @as([]const u8, "No backlight"));
            try json.set("tooltip", @as([]const u8, "No backlight detected"));
            try json.write(stdout);
            try stdout.flush();

            if (err == error.NotFound) continue;
            return err;
        };

        defer info.deinit(gpa);

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKeyAny("percentage", info.percentage);
        try replacer.addKeyAny("brightness", info.brightness);
        try replacer.addKeyAny("max_brightness", info.max_brightness);
        try replacer.addKey("name", info.name);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.set("percentage", info.percentage);

        try json.write(stdout);
        try stdout.flush();
    }
}
