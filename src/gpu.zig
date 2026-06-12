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

const sysinfo = @import("sysinfo").gpu;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const ArrayList = std.ArrayList;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 16,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {usage_percentage}% {dot} {temperature}°C",
    tooltip: []const u8 = "PWM {dot} {pwm_percentage}%{nl}VRAM Total {dot} {vram_total:.0}{nl}VRAM Free {dot} {vram_free:.2}{nl}VRAM Usage {dot} {vram_usage:.2}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, gpa);
    const config = try cfg.load("gpu", ModuleConfig);
    defer cfg.free(config);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    var module: sysinfo = .init(gpa);
    try module.initialize();
    defer module.shutdown();

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const gpu_info: sysinfo.GPUInfo = try module.getInfo();

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", config.icon);
        try replacer.addKeyAny("usage_percentage", gpu_info.gpu_busy);
        try replacer.addKeyAny("temperature", gpu_info.temperature);
        try replacer.addKeyAny("pwm_percentage", gpu_info.pwm);
        try replacer.addKeyAny("vram_total", gpu_info.memory_info.total);
        try replacer.addKeyAny("vram_usage", gpu_info.memory_info.used);
        try replacer.addKeyAny("vram_free", gpu_info.memory_info.free);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        const tooltip_line = try replacer.render(config.tooltip);
        try json.set("tooltip", tooltip_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
