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
// along with this program. If not, see <https://gnu.org/licenses/>.

const sysinfo = @import("sysinfo").network;

const std = @import("std");
const utils = @import("utils");
const process = std.process;
const Io = std.Io;
const File = Io.File;
const Clock = Io.Clock;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {total_speed:^1}",
    tooltip: []const u8 = "Interface {dot} {interface:nl}Gateway {dot} {gateway:nl}Local IP {dot} {local_ip:nl:nl}Download {dot} {download_speed:^1:nl}Upload {dot} {upload_speed:^1}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("network", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    const route = sysinfo.getDefaultRoute(io, gpa) catch {
        try json.set("text", @as([]const u8, "Disconnected"));
        try json.set("tooltip", @as([]const u8, "No active network route"));
        try json.setClass("disconnected");
        try json.write(stdout);
        try stdout.flush();
        return;
    };
    const local_ip = sysinfo.getLocalIP(gpa, route.interface) catch "0.0.0.0";

    const initial_time = Clock.now(.boot, io);
    var prev_stats = sysinfo.getNetworkStats(io, route.interface, initial_time.toSeconds()) catch sysinfo.NetworkStats{ .rx_bytes = 0, .tx_bytes = 0, .timestamp = initial_time.toSeconds() };

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        const current_time = Clock.now(.boot, io);
        const timestamp = current_time.toSeconds();

        const current_stats = sysinfo.getNetworkStats(io, route.interface, timestamp) catch continue;

        const rates = sysinfo.NetworkStats.calculateRates(prev_stats, current_stats);
        prev_stats = current_stats;

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKey("interface", route.interface);
        try replacer.addKey("gateway", route.gateway);
        try replacer.addKey("local_ip", local_ip);
        try replacer.addKeyAny("download_speed", rates.download);
        try replacer.addKeyAny("upload_speed", rates.upload);
        try replacer.addKeyAny("total_speed", rates.total);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.setClass("connected");

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
