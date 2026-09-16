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
const Allocator = mem.Allocator;

const utils = @import("utils");
const Replacer = utils.Replacer;
const runner = @import("../runner.zig");

fn benchReplacerPopulation(allocator: Allocator, _: void) !void {
    var replacer = Replacer.init(allocator);
    defer replacer.deinit();

    try replacer.addCommonPlaceholders();
    try replacer.addKey("icon", "");
    try replacer.addKeyAny("usage_percentage", @as(i64, 45));
    try replacer.addKeyAny("frequency", @as(f64, 3.456));
    try replacer.addKeyAny("frequency_unit", "GHz");
    try replacer.addKeyAny("core_count", @as(usize, 16));
}

fn benchReplacerRenderText(allocator: Allocator, _: void) !void {
    var replacer = Replacer.init(allocator);
    defer replacer.deinit();

    try replacer.addCommonPlaceholders();
    try replacer.addKey("icon", "");
    try replacer.addKeyAny("usage_percentage", @as(i64, 45));
    try replacer.addKeyAny("frequency", @as(f64, 3.456));
    try replacer.addKeyAny("frequency_unit", "GHz");

    const rendered = try replacer.render("{icon}  {usage_percentage:'%'} {dot} {frequency:2:frequency_unit}");
    defer replacer.free(rendered);
}

fn benchReplacerRenderUnits(allocator: Allocator, _: void) !void {
    var replacer = Replacer.init(allocator);
    defer replacer.deinit();

    try replacer.addKeyAny("bytes_used", @as(i64, 1073741824 * 5 + 500000000));
    try replacer.addKeyAny("net_speed", @as(f64, 125000000.0));

    const rendered = try replacer.render("RAM: {bytes_used:.2} | Net: {net_speed:^1}");
    defer replacer.free(rendered);
}

const ReusedReplacerContext = struct {
    replacer: *Replacer,
};

fn benchReplacerReuse(allocator: Allocator, ctx: ReusedReplacerContext) !void {
    _ = allocator;
    defer ctx.replacer.clear();

    try ctx.replacer.addCommonPlaceholders();
    try ctx.replacer.addKey("icon", "");
    try ctx.replacer.addKeyAny("usage_percentage", @as(i64, 45));
    try ctx.replacer.addKeyAny("frequency", @as(f64, 3.456));
    try ctx.replacer.addKeyAny("frequency_unit", "GHz");

    const rendered = try ctx.replacer.render("{icon}  {usage_percentage:'%'} {dot} {frequency:2:frequency_unit}");
    defer ctx.replacer.free(rendered);
}

pub fn runBenchmarks(allocator: Allocator, filter: ?[]const u8) !void {
    const opts: runner.BenchmarkOptions = .{};

    if (filter == null or mem.find(u8, "replacer_population", filter.?) != null) {
        const r1 = try runner.run(allocator, "replacer_population", opts, benchReplacerPopulation, {});
        runner.printResult(r1);
    }

    if (filter == null or mem.find(u8, "replacer_render_format_string", filter.?) != null) {
        const r2 = try runner.run(allocator, "replacer_render_format_string", opts, benchReplacerRenderText, {});
        runner.printResult(r2);
    }

    if (filter == null or mem.find(u8, "replacer_render_units_speed", filter.?) != null) {
        const r3 = try runner.run(allocator, "replacer_render_units_speed", opts, benchReplacerRenderUnits, {});
        runner.printResult(r3);
    }

    if (filter == null or mem.find(u8, "replacer_reuse_with_clear", filter.?) != null) {
        var reused = Replacer.init(allocator);
        defer reused.deinit();
        const r4 = try runner.run(allocator, "replacer_reuse_with_clear", opts, benchReplacerReuse, ReusedReplacerContext{ .replacer = &reused });
        runner.printResult(r4);
    }
}
