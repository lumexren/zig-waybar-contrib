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
const Module = utils.Module;
const Replacer = utils.Replacer;
const ArrayList = std.ArrayList;
const process = std.process;

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
    var mod = try Module(ModuleConfig).init(init, "temperature");
    defer mod.deinit();

    var temp: Temperature = .init(init.io, init.gpa, mod.config.sensor);
    defer temp.deinit();

    var sensor_replacer: Replacer = .init(init.gpa);
    defer sensor_replacer.deinit();

    var sensors_text: ArrayList(u8) = .empty;
    defer sensors_text.deinit(init.gpa);

    while (try mod.tick()) {
        sensors_text.clearRetainingCapacity();

        temp.update() catch |err| {
            try mod.renderError(" N/A", "Temperature sensor not found");
            if (err == Temperature.TemperatureError.SensorNotFound or err == Temperature.TemperatureError.HwmonNotFound) {
                if (mod.config.update_interval == 0) break;
                continue;
            }
            return err;
        };

        try mod.put("sensor", temp.info.sensor_name);
        try mod.put("temp", temp.info.celsius);
        try mod.put("temperature", temp.info.celsius);
        try mod.put("temperature_c", temp.info.celsius);
        try mod.put("temperature_f", temp.info.fahrenheit);
        try mod.put("max_temperature", temp.info.max_celsius);

        for (temp.sensors.items) |s| {
            sensor_replacer.clear();
            try sensor_replacer.addCommonPlaceholders();
            try sensor_replacer.addKey("sensor_name", s.name);
            try sensor_replacer.addKeyAny("sensor_temperature", s.celsius);
            try sensor_replacer.addKeyAny("sensor_temperature_f", s.fahrenheit);

            const sensor_line = try sensor_replacer.render(mod.config.sensor_format);
            defer sensor_replacer.free(sensor_line);

            if (sensors_text.items.len > 0) try sensors_text.append(init.gpa, '\n');
            try sensors_text.appendSlice(init.gpa, sensor_line);
        }

        try mod.putString("sensors", sensors_text.items);

        try mod.render(.{
            .percentage = temp.info.celsius,
        });
    }
}
