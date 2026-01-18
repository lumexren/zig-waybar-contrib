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
// along with this program. If not, see <https://gnu.org/licenses>.

const std = @import("std");
const core = @import("core");
const lib = @import("lib.zig");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const mem = std.mem;
const Io = std.Io;
const Threaded = Io.Threaded;
const File = Io.File;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;
const fmt = std.fmt;
const ascii = std.ascii;

const json = core.json;
const Waybar = core.Waybar;
const Config = core.Config;

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
    const config = try cfg.load("fan", lib.Config);

    var json_builder = json.init(allocator);
    defer json_builder.deinit();

    var fans: ArrayListUnmanaged(lib.FanInfo) = .empty;
    defer fans.deinit(allocator);

    var waybar = try Waybar.init(io, .{ .signal_number = 11 });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json_builder.clear();
        defer fans.clearAndFree(allocator);

        // Iterate over /sys/class/hwmon
        var hwmon_dir = try Io.Dir.openDirAbsolute(io, "/sys/class/hwmon", .{ .iterate = true });
        defer hwmon_dir.close(io);

        var it = hwmon_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory and entry.kind != .sym_link) continue;
            if (!mem.startsWith(u8, entry.name, "hwmon")) continue;

            var device_dir = try hwmon_dir.openDir(io, entry.name, .{ .iterate = true });
            defer device_dir.close(io);

            var dev_it = device_dir.iterate();
            while (try dev_it.next(io)) |dev_entry| {
                if (dev_entry.kind != .file and dev_entry.kind != .sym_link) continue;
                // Look for fan[1-*]_input
                if (mem.startsWith(u8, dev_entry.name, "fan") and mem.endsWith(u8, dev_entry.name, "_input")) {
                    // Read input
                    var file = device_dir.openFile(io, dev_entry.name, .{}) catch continue;
                    defer file.close(io);

                    var buf: [32]u8 = undefined;
                    var slices: [1][]u8 = .{buf[0..]};

                    const len = try file.readStreaming(io, slices[0..]);

                    const speed_str = mem.trim(u8, buf[0..len], &ascii.whitespace);
                    const speed = fmt.parseInt(i64, speed_str, 10) catch 0;

                    if (speed > 0) {
                        // Try to get label or name
                        // Try fanX_label
                        const label_name = try fmt.allocPrint(allocator, "{s}_label", .{dev_entry.name[0..dev_entry.name.len]});
                        var name: []const u8 = "";

                        if (device_dir.openFile(io, label_name, .{})) |label_file| {
                            defer label_file.close(io);

                            var label_buf: [64]u8 = undefined;
                            var label_slices: [1][]u8 = .{label_buf[0..]};
                            const label_len = try label_file.readStreaming(io, label_slices[0..]);

                            if (label_len > 0) name = try allocator.dupe(u8, mem.trim(u8, label_buf[0..label_len], &ascii.whitespace));
                        } else |_| {}

                        // Fallback to device name if no label
                        if (name.len == 0) {
                            if (device_dir.openFile(io, "name", .{})) |name_file| {
                                defer name_file.close(io);

                                var name_buf: [64]u8 = undefined;
                                var name_slices: [1][]u8 = .{name_buf[0..]};
                                const name_len = try name_file.readStreaming(io, name_slices[0..]);

                                if (name_len > 0) {
                                    // Format: device_name fanX
                                    const dev_name = mem.trim(u8, name_buf[0..name_len], &ascii.whitespace);
                                    name = try fmt.allocPrint(allocator, "{s} {s}", .{ dev_name, dev_entry.name[0 .. dev_entry.name.len - 6] });
                                }
                            } else |_| {}
                        }

                        if (name.len == 0) name = try allocator.dupe(u8, dev_entry.name);

                        try fans.append(allocator, .{ .name = name, .speed = speed });
                    }
                }
            }
        }

        if (fans.items.len > 0) {
            var max_speed: i64 = 0;
            for (fans.items) |fan| {
                if (fan.speed > max_speed) max_speed = fan.speed;
            }

            // Build default text
            var default_text_buf: [256]u8 = undefined;
            const default_text = fmt.bufPrint(&default_text_buf, "{s} {d} Fans", .{ config.icon, fans.items.len }) catch "";

            // Build default tooltip
            var default_tooltip_buf: [2048]u8 = undefined;
            var tooltip_writer: Io.Writer = .fixed(&default_tooltip_buf);
            for (fans.items, 0..) |fan, i| {
                if (i > 0) try tooltip_writer.writeByte('\n');
                try tooltip_writer.print("> {s} [{d} RPM]", .{ fan.name, fan.speed });
            }
            const default_tooltip = default_tooltip_buf[0..tooltip_writer.end];

            // Use custom templates if provided
            if (config.text != null or config.tooltip != null) {
                var replacer = core.Replacer.init(allocator);
                defer replacer.deinit();

                try core.output.addCommonPlaceholders(&replacer);
                try replacer.addKey("icon", config.icon);
                try replacer.addKeyAny("fan_count", fans.items.len);
                try replacer.addKeyAny("max_speed", max_speed);

                try core.output.renderText(&json_builder, &replacer, config.text, default_text);
                try core.output.renderTooltip(&json_builder, &replacer, config.tooltip, default_tooltip);
            } else {
                try json_builder.set("text", default_text);
                try json_builder.set("tooltip", default_tooltip);
            }
        }

        try json_builder.write(stdout);
        try stdout.flush();

        try waybar.update();
    }
}
