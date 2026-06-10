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

const sysinfo = @import("sysinfo").memory;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 17,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage}% {dot} {total_usage:.2}",
    tooltip: []const u8 = "Physical Memory{nl}Total {dot} {physical_total:.2}{nl}Used {dot} {physical_used:.2}{nl}Free {dot} {physical_free:.2}{nl}Available {dot} {physical_available:.2}{nl}Shared {dot} {physical_shared:.2}{nl}Buffers {dot} {physical_buffers:.2}{nl}Cached {dot} {physical_cached:.2}{nl}{nl}Swap Memory{nl}Total {dot} {swap_total:.2}{nl}Used {dot} {swap_used:.2}{nl}Free {dot} {swap_free:.2}{nl}Cached {dot} {swap_cached:.2}",
};

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("memory", ModuleConfig);

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const data = try sysinfo.fetchMemoryInfo(io);

        inline for (@typeInfo(@TypeOf(data)).@"struct".field_names, @typeInfo(@TypeOf(data)).@"struct".field_types) |name, FieldType| {
            const value = @field(data, name);

            if (@typeInfo(FieldType) == .@"struct") {
                inline for (@typeInfo(FieldType).@"struct".field_names) |nested_name| {
                    try replacer.addKeyAny(name ++ "_" ++ nested_name, @field(value, nested_name));
                }
            } else {
                try replacer.addKeyAny(name, value);
            }
        }

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);
        try replacer.addKeyAny("total_usage", data.physical.used + data.swap.used);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        const tooltip_line = try replacer.render(config.tooltip);
        try json.set("tooltip", tooltip_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
