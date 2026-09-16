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
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const utils = @import("utils");
const Json = utils.Json;
const runner = @import("../runner.zig");

fn benchJsonBasic(allocator: Allocator, _: void) !void {
    var json = Json.init(allocator);
    defer json.deinit();

    try json.set("text", "42% CPU");
    try json.set("tooltip", "CPU: 42%\nCore 0: 45%\nCore 1: 39%");
    try json.setClass("normal");
    try json.set("percentage", @as(i64, 42));
    try json.set("alt", "active");
}

fn benchJsonFormatted(allocator: Allocator, _: void) !void {
    var json = Json.init(allocator);
    defer json.deinit();

    try json.setFmt("text", "{s}  {d}%", .{ "", 42 });
    try json.setClass("warning");
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 0, 45, 3.20 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 1, 39, 3.15 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 2, 48, 3.30 });
    try json.appendFmtNL("tooltip", "Core {d}: {d}% at {d:.2} GHz", .{ 3, 36, 3.10 });
}

fn benchJsonSerialize(allocator: Allocator, _: void) !void {
    var json = Json.init(allocator);
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

pub fn runBenchmarks(allocator: Allocator, filter: ?[]const u8) !void {
    const opts: runner.BenchmarkOptions = .{};

    if (filter == null or mem.find(u8, "json_basic_set_and_deinit", filter.?) != null) {
        const r1 = try runner.run(allocator, "json_basic_set_and_deinit", opts, benchJsonBasic, {});
        runner.printResult(r1);
    }

    if (filter == null or mem.find(u8, "json_formatted_strings", filter.?) != null) {
        const r2 = try runner.run(allocator, "json_formatted_strings", opts, benchJsonFormatted, {});
        runner.printResult(r2);
    }

    if (filter == null or mem.find(u8, "json_serialize_to_buffer", filter.?) != null) {
        const r3 = try runner.run(allocator, "json_serialize_to_buffer", opts, benchJsonSerialize, {});
        runner.printResult(r3);
    }

    if (filter == null or mem.find(u8, "json_reuse_with_clear", filter.?) != null) {
        var reused_json = Json.init(allocator);
        defer reused_json.deinit();
        const r4 = try runner.run(allocator, "json_reuse_with_clear", opts, benchJsonReuseClear, ReuseContext{ .json = &reused_json });
        runner.printResult(r4);
    }
}
