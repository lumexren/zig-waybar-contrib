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
const Io = std.Io;
const Threaded = Io.Threaded;
const File = Io.File;
const mem = std.mem;
const meta = std.meta;
const debug = std.debug;
const heap = std.heap;
const ArenaAllocator = heap.ArenaAllocator;

const json = core.json;
const Waybar = core.Waybar;
const Config = core.Config;
const network = core.network;
const process = core.process;

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
    const config = try cfg.load("updates", lib.Config);

    var json_builder = json.init(allocator);
    defer json_builder.deinit();

    var error_buffer: [512]u8 = undefined;

    var Module = blk: {
        inline for (meta.fields(lib.Managers)) |field| {
            const manager = @field(lib.Managers, field.name);

            if (try core.findExecutable(init.environ, allocator, io, manager.name())) |_| {
                break :blk lib.init(init.environ, allocator, io, stdout, manager, config);
            }
        }

        @panic("updates: no supported package manager backend found");
    };

    var waybar = try Waybar.init(io, .{ .signal_number = 16 });

    while (true) : (try io.sleep(.fromSeconds(config.check_interval), .boot)) {
        defer json_builder.clear();

        while (try network.resolveIP(allocator, io, "google.com") == null) try io.sleep(.fromSeconds(1), .boot);

        try Module.checkUpdates(&json_builder, &error_buffer);

        try stdout.flush();

        try waybar.update();
    }
}
