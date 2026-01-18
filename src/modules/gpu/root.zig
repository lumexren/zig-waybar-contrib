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
const bo = @import("build_options");
const lib = @import("lib.zig");
const Io = std.Io;
const Threaded = Io.Threaded;
const File = Io.File;
const mem = std.mem;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

const Config = core.Config;
const Waybar = core.Waybar;
const process = core.process;
const json = core.json;

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
    const config = try cfg.load("gpu", lib.Config);

    var json_builder = json.init(allocator);
    defer json_builder.deinit();

    var waybar = try Waybar.init(io, .{ .signal_number = 12 });

    const SMI = blk: {
        if (bo.has_amdsmi) {
            break :blk @import("backend/amdsmi.zig");
        } else if (bo.has_nvml) {
            break :blk @import("backend/nvml.zig");
        } else {
            @compileError("No supported GPU backend found.");
        }
    };

    var Module = SMI.init(allocator);

    try Module.initialize();
    defer Module.shutdown();

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json_builder.clear();

        const gpu_info: lib.GPUInfo = try Module.getInfo();

        const temperature = @as(i64, @intFromFloat(gpu_info.temperature));

        // Build default text and tooltip
        var default_text_buf: [256]u8 = undefined;
        var default_tooltip_buf: [512]u8 = undefined;

        const default_text = std.fmt.bufPrint(&default_text_buf, "{s} {d}% · {d}°C", .{ config.icon, gpu_info.gpu_busy, temperature }) catch "";
        const default_tooltip = std.fmt.bufPrint(&default_tooltip_buf, "PWM · {d}%\nVRAM Total · {Bi:.2}\nVRAM Used · {Bi:.2}\nVRAM Free · {Bi:.2}", .{ gpu_info.pwm, gpu_info.memory_info.total, gpu_info.memory_info.used, gpu_info.memory_info.free }) catch "";

        // Use custom templates if provided
        if (config.text != null or config.tooltip != null) {
            var replacer = core.Replacer.init(allocator);
            defer replacer.deinit();

            try core.output.addCommonPlaceholders(&replacer);
            try replacer.addKey("icon", config.icon);
            try replacer.addKeyAny("gpu_busy", gpu_info.gpu_busy);
            try replacer.addKeyAny("temperature", temperature);
            try replacer.addKeyAny("pwm", gpu_info.pwm);
            try replacer.addKeyAny("vram_total", gpu_info.memory_info.total);
            try replacer.addKeyAny("vram_used", gpu_info.memory_info.used);
            try replacer.addKeyAny("vram_free", gpu_info.memory_info.free);

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
