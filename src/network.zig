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
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 14,
    icon: []const u8 = "󰛳",
    text: []const u8 = "{icon} {total_speed:^1}",
    tooltip: []const u8 = "Interface {dot} {interface}{nl}Gateway {dot} {gateway}{nl}Local IP {dot} {local_ip}{nl}{nl}Download {dot} {download_speed:^1}{nl}Upload {dot} {upload_speed:^1}",
};

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("network", ModuleConfig);

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    // Get initial route info
    const route = try sysinfo.getDefaultRoute(io, allocator);
    const local_ip = try sysinfo.getLocalIP(allocator, route.interface);

    // Get initial network stats
    const initial_time = try Clock.now(.boot, io);
    var prev_stats = try sysinfo.getNetworkStats(io, route.interface, initial_time.toSeconds());

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const current_time = try Clock.now(.boot, io);
        const timestamp = current_time.toSeconds();

        // Get current network stats
        const current_stats = sysinfo.getNetworkStats(io, route.interface, timestamp) catch continue;

        // Calculate rates
        const rates = sysinfo.NetworkStats.calculateRates(prev_stats, current_stats);
        prev_stats = current_stats;

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);
        try replacer.addKey("interface", route.interface);
        try replacer.addKey("gateway", route.gateway);
        try replacer.addKey("local_ip", local_ip);
        try replacer.addKeyAny("download_speed", rates.download);
        try replacer.addKeyAny("upload_speed", rates.upload);
        try replacer.addKeyAny("total_speed", rates.total);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        const tooltip_line = try replacer.render(config.tooltip);
        try json.set("tooltip", tooltip_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.update();
    }
}
