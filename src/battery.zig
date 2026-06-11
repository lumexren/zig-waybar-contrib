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

const sysinfo = @import("sysinfo").battery;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const fmt = std.fmt;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 5,
    signal_number: u8 = 11,
    icon: []const u8 = "",
    icon_charging: []const u8 = "",
    icon_full: []const u8 = "",
    text: []const u8 = "{icon}  {percentage}%",
    tooltip: []const u8 = "Battery: {state}{nl}Time remaining: {time_remaining}{nl}Model: {model}",
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

    var cfg: Config = .init(io, init.environ_map, gpa);
    const config = try cfg.load("battery", ModuleConfig);
    defer cfg.free(config);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const battery = sysinfo.getDisplayDevice(gpa) catch |err| {
            try json.set("text", @as([]const u8, "No battery found"));
            try json.set("tooltip", @as([]const u8, "No battery found"));
            try json.write(stdout);
            try stdout.flush();
            try waybar.updateOrRefresh();

            if (err == sysinfo.BatteryError.NotFound) continue;
            return err;
        };

        defer @constCast(&battery).deinit(gpa);

        if (battery.device_type != .battery or !battery.is_present) {
            try json.set("text", @as([]const u8, "No battery found"));
            try json.set("tooltip", @as([]const u8, "No battery found"));
            try json.write(stdout);
            try stdout.flush();
            try waybar.updateOrRefresh();
            continue;
        }

        const percentage: i64 = @intFromFloat(@round(battery.percentage));
        const state_str = stateToString(battery.state);

        const icon = switch (battery.state) {
            .charging, .pending_charge => config.icon_charging,
            .fully_charged => config.icon_full,
            else => config.icon,
        };

        const time_seconds = switch (battery.state) {
            .charging, .pending_charge => battery.time_to_full,
            else => battery.time_to_empty,
        };
        const time_parts = formatTime(time_seconds);

        var time_buf: [32]u8 = undefined;
        const time_remaining = if (time_seconds > 0)
            fmt.bufPrint(&time_buf, "{d}h {d}m", .{ time_parts.hours, time_parts.minutes }) catch "N/A"
        else
            "N/A";

        try Output.addCommonPlaceholders(&replacer);
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
        try replacer.addKeyAny("energy_rate", battery.energy_rate);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        const tooltip_line = try replacer.render(config.tooltip);
        try json.set("tooltip", tooltip_line);

        try json.set("percentage", percentage);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
