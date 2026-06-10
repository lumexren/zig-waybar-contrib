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

const dbus = @import("bindings").dbus;

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

const BACKLIGHT_PATH = "/sys/class/backlight";

pub const BacklightError = error{
    NotFound,
    InvalidData,
    PermissionDenied,
};

pub const BacklightInfo = struct {
    name: []const u8,
    brightness: u32,
    max_brightness: u32,
    percentage: u8,

    pub fn deinit(this: *@This(), allocator: Allocator) void {
        allocator.free(this.name);
        this.* = undefined;
    }
};

pub fn getBacklights(io: Io, allocator: Allocator) ![]BacklightInfo {
    var backlights: ArrayList(BacklightInfo) = .empty;
    errdefer {
        for (backlights.items) |*b| b.deinit(allocator);
        backlights.deinit(allocator);
    }

    var dir = Dir.openDirAbsolute(io, BACKLIGHT_PATH, .{ .iterate = true }) catch
        return backlights.toOwnedSlice(allocator);
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        const backlight = readBacklightInfo(io, allocator, dir, entry.name) catch continue;
        try backlights.append(allocator, backlight);
    }

    return backlights.toOwnedSlice(allocator);
}

pub fn getBacklight(io: Io, allocator: Allocator, name: []const u8) !BacklightInfo {
    var dir = try Dir.openDirAbsolute(io, BACKLIGHT_PATH, .{});
    defer dir.close(io);

    return readBacklightInfo(io, allocator, dir, name);
}

pub fn getDefaultBacklight(io: Io, allocator: Allocator) !BacklightInfo {
    const backlights = try getBacklights(io, allocator);

    if (backlights.len == 0) {
        allocator.free(backlights);
        return BacklightError.NotFound;
    }

    defer {
        if (backlights.len > 1) {
            for (backlights[1..]) |*b| @constCast(b).deinit(allocator);
        }

        allocator.free(backlights);
    }

    return backlights[0];
}

fn readBacklightInfo(io: Io, allocator: Allocator, parent_dir: Dir, name: []const u8) !BacklightInfo {
    var dir = try parent_dir.openDir(io, name, .{});
    defer dir.close(io);

    const brightness = try readFileU32(io, dir, "brightness");
    const max_brightness = try readFileU32(io, dir, "max_brightness");

    const percentage: u8 = if (max_brightness > 0)
        @intCast(@min(brightness * 100 / max_brightness, 100))
    else
        0;

    return .{
        .name = try allocator.dupe(u8, name),
        .brightness = brightness,
        .max_brightness = max_brightness,
        .percentage = percentage,
    };
}

pub fn setBrightness(io: Io, name: []const u8, value: u32) !void {
    var path_buf: [256]u8 = undefined;
    const path = try fmt.bufPrint(&path_buf, "{s}/{s}/brightness", .{ BACKLIGHT_PATH, name });

    var file = try Dir.openFileAbsolute(io, path, .{ .mode = .write_only });
    defer file.close(io);

    var buf: [16]u8 = undefined;
    const data = try fmt.bufPrint(&buf, "{d}", .{value});
    _ = try file.writeStreaming(io, &.{data});
}

pub fn setBrightnessPercent(io: Io, allocator: Allocator, name: []const u8, percent: u8) !void {
    var dir = try Dir.openDirAbsolute(io, BACKLIGHT_PATH, .{});
    defer dir.close(io);

    const info = try readBacklightInfo(io, allocator, dir, name);
    defer @constCast(&info).deinit(allocator);

    const clamped: u32 = @min(percent, 100);
    const value = info.max_brightness * clamped / 100;
    try setBrightness(io, name, value);
}

pub fn increaseBrightness(io: Io, allocator: Allocator, name: []const u8, step: u8) !void {
    const info = try getBacklight(io, allocator, name);
    defer @constCast(&info).deinit(allocator);

    const new_percent = @min(info.percentage + step, 100);
    try setBrightnessPercent(io, allocator, name, new_percent);
}

pub fn decreaseBrightness(io: Io, allocator: Allocator, name: []const u8, step: u8) !void {
    const info = try getBacklight(io, allocator, name);
    defer @constCast(&info).deinit(allocator);

    const new_percent = info.percentage -| step;
    try setBrightnessPercent(io, allocator, name, new_percent);
}

fn readFileU32(io: Io, dir: Dir, filename: []const u8) !u32 {
    var file = try dir.openFile(io, filename, .{});
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const len = try file.readStreaming(io, &.{buf[0..]});
    const trimmed = mem.trim(u8, buf[0..len], &ascii.whitespace);
    return fmt.parseInt(u32, trimmed, 10);
}

// Tests

const testing = std.testing;

test "BacklightInfo.deinit" {
    const info = BacklightInfo{
        .name = try testing.allocator.dupe(u8, "test_backlight"),
        .brightness = 50,
        .max_brightness = 100,
        .percentage = 50,
    };

    var mutable = info;
    mutable.deinit(testing.allocator);
}

test "getBacklights - no crash on missing path" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const backlights = getBacklights(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer {
        for (backlights) |*b| @constCast(b).deinit(testing.allocator);
        testing.allocator.free(backlights);
    }

    // All backlights should have valid percentages
    for (backlights) |b| {
        try testing.expect(b.percentage <= 100);
        try testing.expect(b.brightness <= b.max_brightness);
    }
}

test "percentage calculation" {
    // 50/100 = 50%
    try testing.expectEqual(@as(u8, 50), @as(u8, @intCast(@min(@as(u32, 50) * 100 / @as(u32, 100), 100))));

    // 255/255 = 100%
    try testing.expectEqual(@as(u8, 100), @as(u8, @intCast(@min(@as(u32, 255) * 100 / @as(u32, 255), 100))));

    // 0/100 = 0%
    try testing.expectEqual(@as(u8, 0), @as(u8, @intCast(@min(@as(u32, 0) * 100 / @as(u32, 100), 100))));
}
