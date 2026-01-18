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

const std = @import("std");
const core = @import("core");
const lib = @import("lib.zig");
const Io = std.Io;
const Threaded = Io.Threaded;
const File = Io.File;
const Clock = Io.Clock;
const Duration = Io.Duration;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

const json = core.json;
const Waybar = core.Waybar;
const Config = core.Config;
const network = core.network;

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
    const config = try cfg.load("ping", lib.Config);

    var json_builder = json.init(allocator);
    defer json_builder.deinit();

    var waybar = try Waybar.init(io, .{ .signal_number = 15 });

    var resolved = try network.resolveIP(allocator, io, config.target_domain);
    var last_update_ts: i64 = undefined;

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json_builder.clear();

        const current = try Clock.now(.boot, io);
        const now_s = current.toSeconds();

        if (resolved == null or (now_s - last_update_ts) >= config.ip_update_interval) {
            resolved = try network.resolveIP(allocator, io, config.target_domain);
            last_update_ts = now_s;
        }

        var buffer: [64]u8 = undefined;

        const latency = try lib.ping(io, &buffer, resolved.?);

        // Build default text and tooltip
        var default_text_buf: [256]u8 = undefined;
        var default_tooltip_buf: [256]u8 = undefined;

        const default_text = std.fmt.bufPrint(&default_text_buf, "{s} {d}ms", .{ config.icon, latency }) catch "";
        const default_tooltip = std.fmt.bufPrint(&default_tooltip_buf, "Domain · {s}\nDomain IP · {s}", .{ config.target_domain, resolved.? }) catch "";

        // Use custom templates if provided
        if (config.text != null or config.tooltip != null) {
            var replacer = core.Replacer.init(allocator);
            defer replacer.deinit();

            try core.output.addCommonPlaceholders(&replacer);
            try replacer.addKey("icon", config.icon);
            try replacer.addKeyAny("latency", latency);
            try replacer.addKey("domain", config.target_domain);
            try replacer.addKey("domain_ip", resolved.?);

            try core.output.renderText(&json_builder, &replacer, config.text, default_text);
            try core.output.renderTooltip(&json_builder, &replacer, config.tooltip, default_tooltip);
        } else {
            try json_builder.set("text", default_text);
            try json_builder.set("tooltip", default_tooltip);
        }

        try json_builder.write(stdout);

        try stdout.flush();

        try waybar.update();
    }
}
