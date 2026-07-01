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

const sysinfo = @import("sysinfo").disk;

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
    update_interval: i64 = 30,
    signal_number: u8 = 14,
    path: []const u8 = "/",
    show_all_mounts: bool = false,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage_used}% {dot} {used:.2}",
    tooltip: []const u8 = "Total {dot} {total:.2}{nl}Free {dot} {free:.2}{nl}Used {dot} {used:.2}",
    mount_tooltip: []const u8 = "{mount_point}: {percentage_used}% ({free:.2} free)",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("disk", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = data.signal_number });

    while (true) : (try io.sleep(.fromSeconds(data.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const disk_info = sysinfo.fetchDiskInfo(data.path) catch {
            try json.set("text", @as([]const u8, "Disk: Error"));
            try json.set("tooltip", @as([]const u8, "Failed to read disk info"));
            try json.write(stdout);
            try stdout.flush();
            try waybar.updateOrRefresh();
            continue;
        };

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKey("path", data.path);
        try replacer.addKeyAny("total", disk_info.total);
        try replacer.addKeyAny("used", disk_info.used);
        try replacer.addKeyAny("free", disk_info.free);
        try replacer.addKeyAny("percentage_used", disk_info.percentage_used);
        try replacer.addKeyAny("percentage_free", disk_info.percentage_free);
        try replacer.addKeyAny("inodes_total", disk_info.inodes_total);
        try replacer.addKeyAny("inodes_used", disk_info.inodes_used);
        try replacer.addKeyAny("inodes_free", disk_info.inodes_free);
        try replacer.addKeyAny("inodes_percentage_used", disk_info.inodes_percentage_used);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        if (data.show_all_mounts) {
            const filesystems = sysinfo.fetchMountedFilesystems(gpa) catch {
                try json.set("tooltip", @as([]const u8, "Failed to read mounted filesystems"));
                try json.write(stdout);
                try stdout.flush();
                try waybar.updateOrRefresh();
                continue;
            };
            defer sysinfo.freeMountedFilesystems(gpa, filesystems);

            var tooltip_text: ArrayList(u8) = .empty;
            defer tooltip_text.deinit(replacer.allocator);

            for (filesystems) |fs| {
                try replacer.addKey("device", fs.device);
                try replacer.addKey("mount_point", fs.mount_point);
                try replacer.addKey("fs_type", fs.fs_type);
                try replacer.addKeyAny("total", fs.disk_info.total);
                try replacer.addKeyAny("used", fs.disk_info.used);
                try replacer.addKeyAny("free", fs.disk_info.free);
                try replacer.addKeyAny("percentage_used", fs.disk_info.percentage_used);
                try replacer.addKeyAny("percentage_free", fs.disk_info.percentage_free);

                const line = try replacer.render(data.mount_tooltip);
                defer replacer.free(line);

                if (tooltip_text.items.len > 0) try tooltip_text.append(replacer.allocator, '\n');
                try tooltip_text.appendSlice(replacer.allocator, line);
            }

            try json.set("tooltip", tooltip_text.items);
        } else {
            const tooltip_line = try replacer.render(data.tooltip);
            defer replacer.free(tooltip_line);

            try json.set("tooltip", tooltip_line);
        }

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
