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

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const utils = @import("utils");
const Replacer = utils.Replacer;
const runner = @import("../runner.zig");
const reporter_mod = @import("../reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const BENCHMARKS = [_][]const u8{
    "replacer_population",
    "replacer_render_format_string",
    "replacer_render_units_speed",
    "replacer_reuse_with_clear",
    "replacer_complex_template",
};

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

fn benchReplacerComplexTemplate(allocator: Allocator, _: void) !void {
    var replacer = Replacer.init(allocator);
    defer replacer.deinit();

    try replacer.addCommonPlaceholders();
    try replacer.addKey("device", "nvme0n1");
    try replacer.addKey("mount", "/home");
    try replacer.addKeyAny("read_bytes", @as(i64, 1024 * 1024 * 850));
    try replacer.addKeyAny("write_bytes", @as(i64, 1024 * 1024 * 240));
    try replacer.addKeyAny("read_rate", @as(f64, 1024 * 1024 * 45.5));
    try replacer.addKeyAny("write_rate", @as(f64, 1024 * 1024 * 12.3));
    try replacer.addKeyAny("disk_used_pct", @as(i64, 68));
    try replacer.addKeyAny("free_space", @as(i64, 1024 * 1024 * 1024 * 120));

    const rendered = try replacer.render("Disk {device} ({mount}): {disk_used_pct:'%'} {dot} R: {read_rate:^1}/s {dot} W: {write_rate:^1}/s {dot} Free: {free_space:.1}");
    defer replacer.free(rendered);
}

fn shouldRun(name: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return mem.find(u8, name, f) != null or mem.eql(u8, f, "replacer");
}

pub fn runBenchmarks(allocator: Allocator, reporter: *Reporter, writer: anytype, options: runner.BenchmarkOptions, filter: ?[]const u8) !void {
    if (shouldRun("replacer_population", filter)) {
        const r = try runner.run(allocator, "replacer_population", options, benchReplacerPopulation, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("replacer_render_format_string", filter)) {
        const r = try runner.run(allocator, "replacer_render_format_string", options, benchReplacerRenderText, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("replacer_render_units_speed", filter)) {
        const r = try runner.run(allocator, "replacer_render_units_speed", options, benchReplacerRenderUnits, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("replacer_reuse_with_clear", filter)) {
        var reused = Replacer.init(allocator);
        defer reused.deinit();
        const r = try runner.run(allocator, "replacer_reuse_with_clear", options, benchReplacerReuse, ReusedReplacerContext{ .replacer = &reused });
        try reporter.report(writer, r);
    }

    if (shouldRun("replacer_complex_template", filter)) {
        const r = try runner.run(allocator, "replacer_complex_template", options, benchReplacerComplexTemplate, {});
        try reporter.report(writer, r);
    }
}
