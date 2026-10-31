// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 lumexren
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
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const utils = @import("utils");
const Json = utils.Json;
const runner = @import("../runner.zig");
const reporter_mod = @import("../reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const BENCHMARKS = [_][]const u8{
    "json_basic_set_and_deinit",
    "json_formatted_strings",
    "json_serialize_to_buffer",
    "json_reuse_with_clear",
    "json_complex_tooltip",
    "json_write_escaped",
};

fn benchJsonBasic(allocator: Allocator, _: void) !void {
    var json: Json = .init(allocator);
    defer json.deinit();

    try json.set("text", "42% CPU");
    try json.set("tooltip", "CPU: 42%\nCore 0: 45%\nCore 1: 39%");
    try json.setClass("normal");
    try json.set("percentage", @as(i64, 42));
    try json.set("alt", "active");
}

fn benchJsonFormatted(allocator: Allocator, _: void) !void {
    var json: Json = .init(allocator);
    defer json.deinit();

    try json.setFmt("text", "{s}  {d}%", .{ "", 42 });
    try json.setClass("warning");
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 0, 45, 3.20 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 1, 39, 3.15 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 2, 48, 3.30 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 3, 36, 3.10 });
}

fn benchJsonSerialize(allocator: Allocator, _: void) !void {
    var json: Json = .init(allocator);
    defer json.deinit();

    try json.set("text", "  42% • 3.20 GHz");
    try json.set("tooltip", "Core 0: 45% • 3.20 GHz\nCore 1: 39% • 3.15 GHz");
    try json.setClass("normal");
    try json.set("percentage", @as(i64, 42));

    var buffer: [1024]u8 = undefined;
    var fbs = Io.Writer.fixed(&buffer);
    try json.write(&fbs);
}

const ReuseContext = struct {
    json: *Json,
};

fn benchJsonReuseClear(allocator: Allocator, ctx: ReuseContext) !void {
    _ = allocator;
    defer ctx.json.clear();

    try ctx.json.set("text", "  42% • 3.20 GHz");
    try ctx.json.set("tooltip", "Core 0: 45% • 3.20 GHz\nCore 1: 39% • 3.15 GHz");
    try ctx.json.setClass("normal");
    try ctx.json.set("percentage", @as(i64, 42));

    var buffer: [1024]u8 = undefined;
    var fbs = Io.Writer.fixed(&buffer);
    try ctx.json.write(&fbs);
}

fn benchJsonComplexTooltip(allocator: Allocator, _: void) !void {
    var json: Json = .init(allocator);
    defer json.deinit();

    try json.set("text", "  CPU 55% | 3.4 GHz | 62°C");
    const classes = [_][]const u8{ "warning", "high-load", "throttling" };
    try json.setClasses(&classes);
    try json.set("percentage", @as(i64, 55));

    inline for (0..8) |core_idx| {
        try json.appendFmtNL("tooltip", "Core {d}: {d}% @ {d:.2} GHz (temp: {d}°C)", .{
            core_idx,
            40 + core_idx * 3,
            3.2 + @as(f64, @floatFromInt(core_idx)) * 0.05,
            55 + core_idx,
        });
    }

    var buffer: [2048]u8 = undefined;
    var fbs = Io.Writer.fixed(&buffer);
    try json.write(&fbs);
}

fn benchJsonWriteEscaped(allocator: Allocator, _: void) !void {
    _ = allocator;
    const test_str = "Status: \"Running\"\nPath: /dev/sda1\tType: ext4\rDetails: \\root\\ \x08\x0c";
    var buffer: [512]u8 = undefined;
    var fbs = Io.Writer.fixed(&buffer);
    try Json.writeEscaped(&fbs, test_str);
}

fn shouldRun(name: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return mem.find(u8, name, f) != null or mem.eql(u8, f, "json");
}

pub fn runBenchmarks(allocator: Allocator, reporter: *Reporter, writer: anytype, options: runner.BenchmarkOptions, filter: ?[]const u8) !void {
    if (shouldRun("json_basic_set_and_deinit", filter)) {
        const r = try runner.run(allocator, "json_basic_set_and_deinit", options, benchJsonBasic, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("json_formatted_strings", filter)) {
        const r = try runner.run(allocator, "json_formatted_strings", options, benchJsonFormatted, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("json_serialize_to_buffer", filter)) {
        const r = try runner.run(allocator, "json_serialize_to_buffer", options, benchJsonSerialize, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("json_reuse_with_clear", filter)) {
        var reused_json: Json = .init(allocator);
        defer reused_json.deinit();
        const r = try runner.run(allocator, "json_reuse_with_clear", options, benchJsonReuseClear, ReuseContext{ .json = &reused_json });
        try reporter.report(writer, r);
    }

    if (shouldRun("json_complex_tooltip", filter)) {
        const r = try runner.run(allocator, "json_complex_tooltip", options, benchJsonComplexTooltip, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("json_write_escaped", filter)) {
        const r = try runner.run(allocator, "json_write_escaped", options, benchJsonWriteEscaped, {});
        try reporter.report(writer, r);
    }
}
