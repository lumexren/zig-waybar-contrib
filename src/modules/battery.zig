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

const sysinfo = @import("sysinfo").battery;

const plume = @import("plume");
const Connection = plume.Connection;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const mem = std.mem;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 5,
    warning_threshold: ?f64 = 20.0,
    critical_threshold: ?f64 = 10.0,
    icon: []const u8 = "",
    icon_charging: []const u8 = "",
    icon_full: []const u8 = "",
    text: []const u8 = "{icon}  {percentage}%",
    tooltip: []const u8 = "Battery: {state:nl}Time remaining: {time_remaining:nl}Model: {model}",
};

fn formatTime(seconds: i64) struct { hours: i64, minutes: i64 } {
    if (seconds <= 0) return .{ .hours = 0, .minutes = 0 };
    const hours = @divFloor(seconds, 3600);
    const minutes = @divFloor(@mod(seconds, 3600), 60);
    return .{ .hours = hours, .minutes = minutes };
}

fn stateToString(state: sysinfo.BatteryState) []const u8 {
    return switch (state) {
        .unknown => "Unknown",
        .charging => "Charging",
        .discharging => "Discharging",
        .empty => "Empty",
        .fully_charged => "Full",
        .pending_charge => "Pending Charge",
        .pending_discharge => "Pending Discharge",
    };
}

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("battery", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var connection: Connection = try .init(io, gpa, .System, init.environ_map);
    defer connection.close();

    var battery_sys: sysinfo = .init(io, gpa, &connection);
    defer battery_sys.deinit();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        const battery = battery_sys.getDisplayDevice() catch |err| {
            try json.set("text", @as([]const u8, "No battery found"));
            try json.set("tooltip", @as([]const u8, "No battery found"));
            try json.setClass("unknown");
            try json.write(stdout);
            try stdout.flush();

            if (err == sysinfo.BatteryError.NotFound) {
                if (data.update_interval == 0) break;
                continue;
            }
            return err;
        };

        defer @constCast(&battery).deinit(gpa);

        if (battery.device_type != .battery or !battery.is_present) {
            try json.set("text", @as([]const u8, "No battery found"));
            try json.set("tooltip", @as([]const u8, "No battery found"));
            try json.setClass("unknown");
            try json.write(stdout);
            try stdout.flush();
            if (data.update_interval == 0) break;
            continue;
        }

        const percentage: i64 = @intFromFloat(@round(battery.percentage));
        const state_str = stateToString(battery.state);

        const icon = switch (battery.state) {
            .charging, .pending_charge => data.icon_charging,
            .fully_charged => data.icon_full,
            else => data.icon,
        };

        const time_seconds = switch (battery.state) {
            .charging, .pending_charge => battery.time_to_full,
            else => battery.time_to_empty,
        };
        const time_parts = formatTime(time_seconds);

        var time_buf: [32]u8 = undefined;
        const time_remaining = if (time_seconds > 0)
            mem.print(&time_buf, "{d}h {d}m", .{ time_parts.hours, time_parts.minutes }) catch "N/A"
        else
            "N/A";

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", icon);
        try replacer.addKeyAny("percentage", percentage);
        try replacer.addKey("state", state_str);
        try replacer.addKey("time_remaining", time_remaining);
        try replacer.addKeyAny("time_to_empty", battery.time_to_empty);
        try replacer.addKeyAny("time_to_full", battery.time_to_full);
        try replacer.addKey("model", battery.model orelse "Unknown");
        try replacer.addKey("vendor", battery.vendor orelse "Unknown");
        try replacer.addKeyAny("voltage", battery.voltage);
        try replacer.addKeyAny("energy", battery.energy);
        try replacer.addKeyAny("energy_full", battery.energy_full);
        try replacer.addKeyAny("energy_full_design", battery.energy_full_design);
        try replacer.addKeyAny("energy_rate", battery.energy_rate);
        try replacer.addKeyAny("power_w", battery.energy_rate);
        try replacer.addKeyAny("power_watts", battery.energy_rate);
        if (battery.health) |h| {
            try replacer.addKeyAny("health", h);
        } else {
            try replacer.addKey("health", "N/A");
        }

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.set("percentage", percentage);

        var classes_buf: [3][]const u8 = undefined;
        var class_count: usize = 0;

        switch (battery.state) {
            .charging, .pending_charge => {
                classes_buf[class_count] = "charging";
                class_count += 1;
            },
            .fully_charged => {
                classes_buf[class_count] = "full";
                class_count += 1;
            },
            .discharging, .pending_discharge => {
                classes_buf[class_count] = "discharging";
                class_count += 1;
            },
            else => {},
        }

        const pct_f64 = battery.percentage;
        if (data.critical_threshold) |crit| {
            if (pct_f64 <= crit) {
                classes_buf[class_count] = "critical";
                class_count += 1;
            } else if (data.warning_threshold) |warn| {
                if (pct_f64 <= warn) {
                    classes_buf[class_count] = "warning";
                    class_count += 1;
                }
            }
        } else if (data.warning_threshold) |warn| {
            if (pct_f64 <= warn) {
                classes_buf[class_count] = "warning";
                class_count += 1;
            }
        }

        if (class_count > 0) {
            try json.setClasses(classes_buf[0..class_count]);
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
