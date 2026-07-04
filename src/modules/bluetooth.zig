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

const sysinfo = @import("sysinfo").bluetooth;

const std = @import("std");
const utils = @import("utils");
const ArrayList = std.ArrayList;
const Io = std.Io;
const File = Io.File;
const process = std.process;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;

pub const ModuleConfig = struct {
    update_interval: i64 = 5,
    signal_number: u8 = 12,
    icon_on: []const u8 = "",
    icon_off: []const u8 = "",
    text: []const u8 = "{icon}  {device_count}",
    tooltip: []const u8 = "Adapter: {adapter_name:nl}Power: {adapter_powered:nl}Connected: {device_count} devices{nl:devices}",
    device_format: []const u8 = "{device_alias}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("bluetooth", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = data.signal_number });

    while (true) : (try io.sleep(.fromSeconds(data.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const adapters = sysinfo.getAdapters(gpa) catch |err| {
            try json.set("text", data.icon_off);
            try json.set("tooltip", @as([]const u8, "Bluetooth unavailable"));
            try json.write(stdout);
            try stdout.flush();
            try waybar.updateOrRefresh();

            if (err == sysinfo.BluetoothError.NoAdapter or err == sysinfo.BluetoothError.ConnectionFailed) continue;
            return err;
        };

        defer {
            for (adapters) |*a| @constCast(a).deinit(gpa);
            gpa.free(adapters);
        }

        if (adapters.len == 0) {
            try json.set("text", data.icon_off);
            try json.set("tooltip", @as([]const u8, "No Bluetooth adapter"));
            try json.write(stdout);
            try stdout.flush();
            try waybar.updateOrRefresh();
            continue;
        }

        const adapter = adapters[0];

        const devices = sysinfo.getDevices(gpa) catch &[_]sysinfo.DeviceInfo{};
        defer {
            for (devices) |*d| @constCast(d).deinit(gpa);
            gpa.free(devices);
        }

        var connected_count: usize = 0;
        for (devices) |d| {
            if (d.connected) connected_count += 1;
        }

        var device_list: ArrayList(u8) = .empty;
        defer device_list.deinit(gpa);

        for (devices) |device| {
            if (!device.connected) continue;

            try replacer.addKey("device_name", device.name orelse "Unknown");
            try replacer.addKey("device_alias", device.alias orelse device.name orelse "Unknown");
            try replacer.addKeyAny("device_connected", device.connected);
            try replacer.addKeyAny("device_battery", device.battery orelse @as(u8, 0));

            const line = try replacer.render(data.device_format);
            if (device_list.items.len > 0) try device_list.appendSlice(gpa, "\n");
            try device_list.appendSlice(gpa, line);
        }

        const icon = if (adapter.powered) data.icon_on else data.icon_off;

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", icon);
        try replacer.addKey("adapter_name", adapter.name orelse "Unknown");
        try replacer.addKeyAny("adapter_powered", adapter.powered);
        try replacer.addKeyAny("adapter_discoverable", adapter.discoverable);
        try replacer.addKeyAny("device_count", connected_count);
        try replacer.addKey("devices", if (device_list.items.len > 0) device_list.items else "No connected devices");

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
