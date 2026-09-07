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

const sysinfo = @import("sysinfo").Memory;

const std = @import("std");
const utils = @import("utils");
const mem = std.mem;
const Io = std.Io;
const File = Io.File;
const process = std.process;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    warning_threshold: ?f64 = 75.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {percentage:'%'} {dot} {total_usage:.2}",
    tooltip: []const u8 = "Physical Memory{nl}Total {dot} {physical_total:.2:nl}Used {dot} {physical_used:.2:nl}Free {dot} {physical_free:.2:nl}Available {dot} {physical_available:.2:nl}Shared {dot} {physical_shared:.2:nl}Buffers {dot} {physical_buffers:.2:nl}Cached {dot} {physical_cached:.2:nl:nl}Swap Memory{nl}Total {dot} {swap_total:.2:nl}Used {dot} {swap_used:.2:nl}Free {dot} {swap_free:.2:nl}Cached {dot} {swap_cached:.2}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("memory", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var memory: sysinfo = .init(io);
    defer memory.deinit();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        try memory.update();

        inline for (@typeInfo(@TypeOf(memory)).@"struct".field_names, @typeInfo(@TypeOf(memory)).@"struct".field_types) |name, FieldType| {
            if (comptime mem.eql(u8, name, "io")) continue;

            const value = @field(memory, name);

            if (@typeInfo(FieldType) == .@"struct") {
                inline for (@typeInfo(FieldType).@"struct".field_names) |nested_name| {
                    try replacer.addKeyAny(name ++ "_" ++ nested_name, @field(value, nested_name));
                }
            } else {
                try replacer.addKeyAny(name, value);
            }
        }

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKeyAny("total_usage", memory.physical.used + memory.swap.used);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        const pct_f64: f64 = @floatFromInt(memory.percentage);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.set("percentage", memory.percentage);

        if (data.critical_threshold) |crit| {
            if (pct_f64 >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (pct_f64 >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("normal");
                }
            } else {
                try json.setClass("normal");
            }
        } else if (data.warning_threshold) |warn| {
            if (pct_f64 >= warn) {
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
