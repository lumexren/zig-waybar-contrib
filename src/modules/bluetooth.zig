// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 lumexren
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

const plume = @import("plume");
const Connection = plume.Connection;

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
    update_interval: i64 = 5,
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

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var connection: Connection = try .init(io, gpa, .System, init.environ_map);
    defer connection.close();

    var bluetooth_sys: sysinfo = .init(io, gpa, &connection);
    defer bluetooth_sys.deinit();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        const adapters = bluetooth_sys.getAdapters() catch |err| {
            try json.set("text", data.icon_off);
            try json.set("tooltip", @as([]const u8, "Bluetooth unavailable"));
            try json.setClass("disabled");
            try json.write(stdout);
            try stdout.flush();

            if (err == sysinfo.BluetoothError.NoAdapter or err == sysinfo.BluetoothError.ConnectionFailed or err == sysinfo.BluetoothError.InvalidResponse) {
                if (data.update_interval == 0) break;
                continue;
            }
            return err;
        };

        defer {
            for (adapters) |*a| @constCast(a).deinit(gpa);
            gpa.free(adapters);
        }

        if (adapters.len == 0) {
            try json.set("text", data.icon_off);
            try json.set("tooltip", @as([]const u8, "No Bluetooth adapter"));
            try json.setClass("disabled");
            try json.write(stdout);
            try stdout.flush();
            if (data.update_interval == 0) break;
            continue;
        }

        const adapter = adapters[0];

        const maybe_devices = bluetooth_sys.getDevices() catch null;
        defer if (maybe_devices) |devs| {
            for (devs) |*d| @constCast(d).deinit(gpa);
            gpa.free(devs);
        };
        const devices = maybe_devices orelse &[_]sysinfo.DeviceInfo{};

        var connected_count: usize = 0;
        var first_device_battery: ?u8 = null;
        for (devices) |d| {
            if (d.connected) {
                connected_count += 1;
                if (first_device_battery == null and d.battery != null) {
                    first_device_battery = d.battery;
                }
            }
        }

        var device_list: ArrayList(u8) = .empty;
        defer device_list.deinit(gpa);

        for (devices) |device| {
            if (!device.connected) continue;

            try replacer.addKey("device_name", device.name orelse "Unknown");
            try replacer.addKey("device_alias", device.alias orelse device.name orelse "Unknown");
            try replacer.addKeyAny("device_connected", device.connected);
            if (device.battery) |bat| {
                try replacer.addKeyAny("device_battery", bat);
            } else {
                try replacer.addKey("device_battery", "");
            }

            const line = try replacer.render(data.device_format);
            defer replacer.free(line);
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
        if (first_device_battery) |bat| {
            try replacer.addKeyAny("battery", bat);
            try replacer.addKeyAny("device_battery", bat);
        } else {
            try replacer.addKey("battery", "");
            try replacer.addKey("device_battery", "");
        }
        try replacer.addKey("devices", if (device_list.items.len > 0) device_list.items else "No connected devices");

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        if (first_device_battery) |bat| {
            try json.set("percentage", bat);
        }

        if (!adapter.powered) {
            try json.setClass("off");
        } else if (connected_count > 0) {
            try json.setClass("connected");
        } else {
            try json.setClass("on");
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
