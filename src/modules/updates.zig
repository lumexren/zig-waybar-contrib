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

const Updates = @import("sysinfo").Updates;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const mem = std.mem;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 200,
    warning_threshold: ?usize = 1,
    critical_threshold: ?usize = 50,
    icon: []const u8 = "",
    error_icon: []const u8 = "",
    manager: ?[]const u8 = null,
    text: []const u8 = "{icon}  {total_updates}",
    tooltip: []const u8 = "{package_name}: {new_version}",
};

fn getManager(name: []const u8) Updates.PackageManager {
    if (mem.eql(u8, name, "apt")) return .apt;
    if (mem.eql(u8, name, "pacman")) return .pacman;
    if (mem.eql(u8, name, "dnf")) return .dnf;
    if (mem.eql(u8, name, "zypper")) return .zypper;
    if (mem.eql(u8, name, "xbps")) return .xbps;

    std.debug.panic("updates: {s} manager is not supported.", .{name});
}

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("updates", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var manager: Updates.PackageManager = undefined;
    if (data.manager) |m| {
        manager = getManager(m);
    } else {
        manager = try Updates.getManager(io, init.environ_map, gpa);
    }

    var updates: Updates = .init(io, init.environ_map, gpa, manager);
    defer updates.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer {
            json.clear();
            replacer.clear();
            updates.clear();
        }

        try replacer.addCommonPlaceholders();

        var is_err = false;
        if (updates.check()) |_| {
            try replacer.addKey("icon", data.icon);
            try replacer.addKeyAny("total_updates", updates.count);
            try replacer.addKey("manager", updates.manager.name());

            if (updates.count > 0) {
                var tooltip_text: ArrayList(u8) = .empty;
                defer tooltip_text.deinit(replacer.allocator);

                for (updates.updates.items) |update| {
                    try replacer.addKey("package_name", update.pkg_name);
                    try replacer.addKey("new_version", update.new_version);

                    const line = try replacer.render(data.tooltip);
                    defer replacer.free(line);

                    if (tooltip_text.items.len > 0) try tooltip_text.append(replacer.allocator, '\n');
                    try tooltip_text.appendSlice(replacer.allocator, line);
                }

                try json.set("tooltip", tooltip_text.items);
            } else {
                try json.set("tooltip", "");
            }
        } else |err| {
            is_err = true;
            try replacer.addKey("icon", data.error_icon);
            try replacer.addKey("manager", updates.manager.name());
            try replacer.addKeyAny("total_updates", updates.count);

            try json.set("tooltip", @errorName(err));
        }

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        try json.set("text", text_line);

        if (is_err) {
            try json.setClass("error");
        } else if (data.critical_threshold) |crit| {
            if (updates.count >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (updates.count >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("updated");
                }
            } else {
                try json.setClass("updated");
            }
        } else if (data.warning_threshold) |warn| {
            if (updates.count >= warn) {
                try json.setClass("warning");
            } else {
                try json.setClass("updated");
            }
        } else {
            try json.setClass("updated");
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
