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

const Temperature = @import("sysinfo").Temperature;

const std = @import("std");
const utils = @import("utils");
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = Io.File;
const process = std.process;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 2,
    sensor: ?[]const u8 = null,
    warning_threshold: ?f64 = 75.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {temperature:1:'°C'}",
    tooltip: []const u8 = "Sensor: {sensor:nl}Temperature: {temperature:1:'°C'} ({temperature_f:1:'°F'}){nl:sensors}",
    sensor_format: []const u8 = "{sensor_name}: {sensor_temperature:1:'°C'}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("temperature", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var temp: Temperature = .init(io, gpa, data.sensor);
    defer temp.deinit();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer {
            json.clear();
            replacer.clear();
        }

        temp.update() catch |err| {
            try json.set("text", @as([]const u8, " N/A"));
            try json.set("tooltip", @as([]const u8, "Temperature sensor not found"));
            try json.setClass("error");
            try json.write(stdout);
            try stdout.flush();

            if (err == Temperature.TemperatureError.SensorNotFound or err == Temperature.TemperatureError.HwmonNotFound) {
                if (data.update_interval == 0) break;
                continue;
            }
            return err;
        };

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKey("sensor", temp.info.sensor_name);
        try replacer.addKeyAny("temp", temp.info.celsius);
        try replacer.addKeyAny("temperature", temp.info.celsius);
        try replacer.addKeyAny("temperature_c", temp.info.celsius);
        try replacer.addKeyAny("temperature_f", temp.info.fahrenheit);
        try replacer.addKeyAny("max_temperature", temp.info.max_celsius);

        var sensors_text: ArrayList(u8) = .empty;
        defer sensors_text.deinit(gpa);

        var sensor_replacer: Replacer = .init(gpa);
        defer sensor_replacer.deinit();

        for (temp.sensors.items) |s| {
            sensor_replacer.clear();
            try sensor_replacer.addCommonPlaceholders();
            try sensor_replacer.addKey("sensor_name", s.name);
            try sensor_replacer.addKeyAny("sensor_temperature", s.celsius);
            try sensor_replacer.addKeyAny("sensor_temperature_f", s.fahrenheit);

            const sensor_line = try sensor_replacer.render(data.sensor_format);
            defer sensor_replacer.free(sensor_line);

            if (sensors_text.items.len > 0) try sensors_text.append(gpa, '\n');
            try sensors_text.appendSlice(gpa, sensor_line);
        }

        try replacer.addKey("sensors", sensors_text.items);

        const text_rendered = try replacer.render(data.text);
        defer replacer.free(text_rendered);

        const tooltip_rendered = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_rendered);

        const temp_int: i64 = @intFromFloat(@round(temp.info.celsius));
        try json.set("text", text_rendered);
        try json.set("tooltip", tooltip_rendered);
        try json.set("percentage", temp_int);

        if (data.critical_threshold) |crit| {
            if (temp.info.celsius >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (temp.info.celsius >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("normal");
                }
            } else {
                try json.setClass("normal");
            }
        } else if (data.warning_threshold) |warn| {
            if (temp.info.celsius >= warn) {
                try json.setClass("warning");
            } else {
                try json.setClass("normal");
            }
        } else {
            try json.setClass("normal");
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
