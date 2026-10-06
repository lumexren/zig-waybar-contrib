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
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 30,
    warning_threshold: ?u8 = 80,
    critical_threshold: ?u8 = 90,
    path: []const u8 = "/",
    device: ?[]const u8 = null,
    show_all_mounts: bool = false,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage_used:'%'} {dot} {used:.2}",
    tooltip: []const u8 = "Total {dot} {total:.2:nl}Free {dot} {free:.2:nl}Used {dot} {used:.2}",
    mount_tooltip: []const u8 = "{mount_point}: {percentage_used:'%'} ({free:.2} free)",
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

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    const initial_time = Io.Clock.now(.boot, io);
    var prev_io_stats: sysinfo.DiskIOStats = sysinfo.getDiskIOStats(io, data.device, initial_time.toSeconds()) catch sysinfo.DiskIOStats{ .read_bytes = 0, .write_bytes = 0, .timestamp = initial_time.toSeconds() };

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        const current_time = Io.Clock.now(.boot, io);
        const timestamp = current_time.toSeconds();
        const current_io_stats = sysinfo.getDiskIOStats(io, data.device, timestamp) catch prev_io_stats;
        const io_rates = sysinfo.DiskIOStats.calculateRates(prev_io_stats, current_io_stats);
        prev_io_stats = current_io_stats;

        const disk_info = sysinfo.fetchDiskInfo(data.path) catch {
            try json.set("text", @as([]const u8, "Disk: Error"));
            try json.set("tooltip", @as([]const u8, "Failed to read disk info"));
            try json.setClass("critical");
            try json.write(stdout);
            try stdout.flush();
            if (data.update_interval == 0) break;
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
        try replacer.addKeyAny("read_speed", io_rates.read);
        try replacer.addKeyAny("write_speed", io_rates.write);
        try replacer.addKeyAny("total_speed", io_rates.total);
        try replacer.addKeyAny("io_speed", io_rates.total);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        if (data.show_all_mounts) {
            const filesystems = sysinfo.fetchMountedFilesystemsIo(io, gpa) catch {
                try json.set("tooltip", @as([]const u8, "Failed to read mounted filesystems"));
                try json.write(stdout);
                try stdout.flush();
                if (data.update_interval == 0) break;
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

        try json.set("text", text_line);
        try json.set("percentage", disk_info.percentage_used);

        if (data.critical_threshold) |crit| {
            if (disk_info.percentage_used >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (disk_info.percentage_used >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("normal");
                }
            } else {
                try json.setClass("normal");
            }
        } else if (data.warning_threshold) |warn| {
            if (disk_info.percentage_used >= warn) {
                try json.setClass("warning");
            } else {
                try json.setClass("normal");
            }
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}
