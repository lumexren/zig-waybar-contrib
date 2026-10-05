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

const sysinfo = @import("sysinfo").gpu;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    warning_threshold: ?f64 = 75.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {usage_percentage:'%'} {dot} {temperature:'°C'}",
    tooltip: []const u8 = "PWM {dot} {pwm_percentage:'%':nl}VRAM Total {dot} {vram_total:.0:nl}VRAM Free {dot} {vram_free:.2:nl}VRAM Usage {dot} {vram_usage:.2}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("gpu", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var module: sysinfo = .init(gpa);
    const initialized = blk: {
        module.initialize() catch break :blk false;
        break :blk true;
    };
    defer if (initialized) module.shutdown();

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        if (!initialized) {
            try json.set("text", "No GPU");
            try json.set("tooltip", "No supported GPU detected");
            try json.setClass("disabled");
            try json.write(stdout);
            try stdout.flush();
            if (data.update_interval == 0) break;
            continue;
        }

        const gpu_info: sysinfo.GPUInfo = module.getInfo() catch {
            try json.set("text", "No GPU");
            try json.set("tooltip", "Failed to query GPU info");
            try json.setClass("disabled");
            try json.write(stdout);
            try stdout.flush();
            if (data.update_interval == 0) break;
            continue;
        };

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKeyAny("usage_percentage", gpu_info.gpu_busy);
        try replacer.addKeyAny("temperature", gpu_info.temperature);
        try replacer.addKeyAny("pwm_percentage", gpu_info.pwm);
        try replacer.addKeyAny("vram_total", gpu_info.memory_info.total);
        try replacer.addKeyAny("vram_usage", gpu_info.memory_info.used);
        try replacer.addKeyAny("vram_free", gpu_info.memory_info.free);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        const usage_f64: f64 = @floatFromInt(gpu_info.gpu_busy);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.set("percentage", gpu_info.gpu_busy);

        if (data.critical_threshold) |crit| {
            if (usage_f64 >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (usage_f64 >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("normal");
                }
            } else {
                try json.setClass("normal");
            }
        } else if (data.warning_threshold) |warn| {
            if (usage_f64 >= warn) {
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
