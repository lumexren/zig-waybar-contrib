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

const Module = @This();

const sysinfo = @import("sysinfo").updates;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const mem = std.mem;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 200,
    signal_number: u8 = 16,
    icon: []const u8 = "",
    err_icon: []const u8 = "",
    manager: ?[]const u8 = null,
    text: []const u8 = "{icon} {total_updates}",
    tooltip: []const u8 = "{package_name}: {new_version}",
};

fn getManager(name: []const u8) sysinfo.Managers {
    if (mem.eql(u8, name, "apt")) return .apt;
    if (mem.eql(u8, name, "pacman")) return .pacman;
    if (mem.eql(u8, name, "dnf")) return .dnf;
    if (mem.eql(u8, name, "zypper")) return .zypper;
    if (mem.eql(u8, name, "xbps")) return .xbps;

    std.debug.panic("updates: {s} manager is not supported.", .{name});
}

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("updates", ModuleConfig);

    var manager: sysinfo.Managers = undefined;
    if (config.manager) |mgr| {
        manager = getManager(mgr);
    } else {
        manager = try sysinfo.getManager(io, init.environ_map, allocator);
    }

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const updates = sysinfo.checkUpdates(io, init.environ_map, allocator, manager) catch null;

        const total_updates: usize = if (updates) |u| u.len else 0;

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);
        try replacer.addKey("err_icon", config.err_icon);
        try replacer.addKeyAny("total_updates", total_updates);
        try replacer.addKey("manager", manager.name());

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        var tooltip_text: ArrayList(u8) = .empty;
        defer tooltip_text.deinit(allocator);

        if (updates) |update_list| {
            for (update_list) |update| {
                const package_name = mem.sliceTo(&update.pkg_name, 0);
                const new_version = mem.sliceTo(&update.new_version, 0);

                try replacer.addKey("package_name", package_name);
                try replacer.addKey("new_version", new_version);

                const line = try replacer.render(config.tooltip);
                if (tooltip_text.items.len > 0) try tooltip_text.append(allocator, '\n');
                try tooltip_text.appendSlice(allocator, line);
            }
        }

        try json.set("tooltip", tooltip_text.items);

        try json.write(stdout);
        try stdout.flush();

        try waybar.update();
    }
}
