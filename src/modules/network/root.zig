// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 - 2026 erffy
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

// This module is experimental and may not work as expected.

const std = @import("std");
const core = @import("core");
const lib = @import("lib.zig");
const Io = std.Io;
const Threaded = Io.Threaded;
const File = Io.File;
const Clock = Io.Clock;
const Duration = Io.Duration;
const mem = std.mem;
const Allocator = mem.Allocator;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

const json = core.json;
const Waybar = core.Waybar;
const Config = core.Config;
const process = core.process;

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: ArenaAllocator = .init(heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: Threaded = .init(allocator, .{ .environ = init.environ });
    const io = threaded.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ, allocator);
    const config = try cfg.load("network", lib.Config);

    var json_builder = json.init(allocator);
    defer json_builder.deinit();

    // Get network information with fallback values
    var route_info = lib.getDefaultRoute(allocator, io) catch null;
    var is_fallback = route_info == null;
    if (is_fallback) {
        route_info = .{
            .interface = try allocator.dupe(u8, "eth0"),
            .gateway = try allocator.dupe(u8, "0.0.0.0"),
        };
    }

    var local_ip = if (route_info) |r| lib.getLocalIP(allocator, r.interface) catch "N/A" else "N/A";

    var waybar = try Waybar.init(io, .{ .signal_number = 14 });

    const initial_time = (try Clock.now(.boot, io)).toSeconds();
    var prev_stats = if (route_info) |r| lib.getNetworkStats(io, r.interface, initial_time) catch lib.NetworkStats{
        .rx_bytes = 0,
        .tx_bytes = 0,
        .timestamp = initial_time,
    } else lib.NetworkStats{
        .rx_bytes = 0,
        .tx_bytes = 0,
        .timestamp = initial_time,
    };

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json_builder.clear();

        // If using fallback, try to detect actual network
        if (is_fallback) {
            if (lib.getDefaultRoute(allocator, io)) |detected_route| {
                route_info = detected_route;
                local_ip = lib.getLocalIP(allocator, detected_route.interface) catch "N/A";
                is_fallback = false;
            } else |_| {
                // Still no network, continue with fallback
            }
        }

        const current_time = (try Clock.now(.boot, io)).toSeconds();
        const current_stats = if (route_info) |r| lib.getNetworkStats(io, r.interface, current_time) catch lib.NetworkStats{
            .rx_bytes = 0,
            .tx_bytes = 0,
            .timestamp = current_time,
        } else lib.NetworkStats{
            .rx_bytes = 0,
            .tx_bytes = 0,
            .timestamp = current_time,
        };

        const rates = lib.NetworkStats.calculateRates(prev_stats, current_stats);

        // Convert rates to bytes for formatting
        const total_bytes: u64 = @intFromFloat(rates.total);
        const download_bytes: u64 = @intFromFloat(rates.download);
        const upload_bytes: u64 = @intFromFloat(rates.upload);

        var ping_buf: [64]u8 = undefined;
        const latency = if (route_info) |r| lib.ping(io, &ping_buf, r.gateway) catch 0 else 0;

        const gateway_str = if (route_info) |r| r.gateway else "0.0.0.0";
        const interface_str = if (route_info) |r| r.interface else "eth0";

        // Build default text and tooltip
        var default_text_buf: [256]u8 = undefined;
        var default_tooltip_buf: [512]u8 = undefined;

        const default_text = std.fmt.bufPrint(&default_text_buf, "{s} {Bi:.1}", .{ config.icon, total_bytes }) catch "";
        const default_tooltip = std.fmt.bufPrint(&default_tooltip_buf, "Gateway · {s}\nLocal IP · {s}\nLatency · {d}ms\nInterface · {s}\n\nDownload · {Bi:.1}\nUpload · {Bi:.1}", .{ gateway_str, local_ip, latency, interface_str, download_bytes, upload_bytes }) catch "";

        // Use custom templates if provided
        if (config.text != null or config.tooltip != null) {
            var replacer = core.Replacer.init(allocator);
            defer replacer.deinit();

            try core.output.addCommonPlaceholders(&replacer);
            try replacer.addKey("icon", config.icon);
            try replacer.addKeyAny("total_bytes", total_bytes);
            try replacer.addKeyAny("download_bytes", download_bytes);
            try replacer.addKeyAny("upload_bytes", upload_bytes);
            try replacer.addKey("gateway", gateway_str);
            try replacer.addKey("local_ip", local_ip);
            try replacer.addKey("interface", interface_str);
            try replacer.addKeyAny("latency", latency);

            try core.output.renderText(&json_builder, &replacer, config.text, default_text);
            try core.output.renderTooltip(&json_builder, &replacer, config.tooltip, default_tooltip);
        } else {
            try json_builder.set("text", default_text);
            try json_builder.set("tooltip", default_tooltip);
        }

        try json_builder.write(stdout);
        try stdout.flush();

        try waybar.update();

        prev_stats = current_stats;
    }
}
