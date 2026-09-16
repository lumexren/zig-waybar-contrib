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

const std = @import("std");
const mem = std.mem;
const debug = std.debug;

const runner = @import("runner.zig");
const bench_json = @import("benchmarks/json.zig");
const bench_replacer = @import("benchmarks/replacer.zig");
const bench_sysinfo = @import("benchmarks/sysinfo.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var filter: ?[]const u8 = null;

    const args = init.minimal.args.vector;
    if (args.len > 1) {
        const candidate = mem.span(args[1]);
        if (mem.eql(u8, candidate, "-h") or mem.eql(u8, candidate, "--help")) {
            debug.print(
                \\Usage: zig build bench [-- [FILTER]]
                \\
                \\Filters:
                \\  json        Run JSON serialization benchmarks
                \\  replacer    Run template string Replacer benchmarks
                \\  sysinfo     Run sysinfo collectors and calculation benchmarks
                \\  <name>      Match specific benchmark by substring
                \\
            , .{});
            return;
        }
        filter = candidate;
    }

    if (filter) |f| {
        debug.print("Active filter: \"{s}\"\n", .{f});
    }

    runner.printHeader();

    if (filter == null or mem.find(u8, "json", filter.?) != null or mem.find(u8, filter.?, "json") != null) {
        try bench_json.runBenchmarks(gpa, filter);
    }

    if (filter == null or mem.find(u8, "replacer", filter.?) != null or mem.find(u8, filter.?, "replacer") != null) {
        try bench_replacer.runBenchmarks(gpa, filter);
    }

    if (filter == null or mem.find(u8, "sysinfo", filter.?) != null or mem.find(u8, filter.?, "sysinfo") != null) {
        try bench_sysinfo.runBenchmarks(gpa, io, filter);
    }
}
