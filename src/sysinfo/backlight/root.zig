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

const Backlight = @This();

pub const BacklightInfo = @import("BacklightInfo.zig");
pub const BacklightError = @import("BacklightError.zig").BacklightError;

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

const BACKLIGHT_PATH = "/sys/class/backlight";

io: Io,
allocator: Allocator,
connection: *Connection,
proxy: Proxy,

/// Initializes the Backlight module.
/// Requires a Connection to the system bus to communicate with logind via D-Bus.
pub inline fn init(io: Io, allocator: Allocator, connection: *Connection) !Backlight {
    return .{
        .io = io,
        .allocator = allocator,
        .connection = connection,
        .proxy = .init(connection, "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session"),
    };
}

/// Safely cleans up the Backlight module's state and D-Bus proxy.
pub fn deinit(this: *Backlight) void {
    this.* = undefined;
}

/// Returns a slice of discovered backlights. The caller owns the slice and the memory of its items.
pub fn getBacklights(this: *Backlight) ![]BacklightInfo {
    var backlights: ArrayList(BacklightInfo) = .empty;
    errdefer {
        for (backlights.items) |*b| b.deinit(this.allocator);
        backlights.deinit(this.allocator);
    }

    var dir = Dir.openDirAbsolute(this.io, BACKLIGHT_PATH, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return backlights.toOwnedSlice(this.allocator),
        else => return err,
    };
    defer dir.close(this.io);

    var it = dir.iterate();
    while (try it.next(this.io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;

        const backlight = this.readBacklightInfo(dir, entry.name) catch continue;
        try backlights.append(this.allocator, backlight);
    }

    return backlights.toOwnedSlice(this.allocator);
}

pub fn getBacklight(this: *Backlight, name: []const u8) !BacklightInfo {
    var dir = try Dir.openDirAbsolute(this.io, BACKLIGHT_PATH, .{});
    defer dir.close(this.io);

    return this.readBacklightInfo(dir, name);
}

pub fn getDefaultBacklight(this: *Backlight) !BacklightInfo {
    const backlights = try this.getBacklights();

    if (backlights.len == 0) {
        this.allocator.free(backlights);
        return BacklightError.NotFound;
    }

    defer {
        if (backlights.len > 1) {
            for (backlights[1..]) |*b| b.deinit(this.allocator);
        }
        this.allocator.free(backlights);
    }

    return backlights[0];
}

fn readBacklightInfo(this: *Backlight, parent_dir: Dir, name: []const u8) !BacklightInfo {
    var dir = try parent_dir.openDir(this.io, name, .{});
    defer dir.close(this.io);

    const brightness = try readFileU32(this.io, dir, "brightness");
    const max_brightness = try readFileU32(this.io, dir, "max_brightness");

    const percentage: u8 = if (max_brightness > 0)
        @intCast(@min(@as(u64, brightness) * 100 / max_brightness, 100))
    else
        0;

    return .{
        .name = try this.allocator.dupe(u8, name),
        .brightness = brightness,
        .max_brightness = max_brightness,
        .percentage = percentage,
    };
}

/// Sets the absolute brightness value via systemd logind D-Bus interface.
pub fn setBrightness(this: *Backlight, name: []const u8, value: u32) !void {
    _ = try this.proxy.call("SetBrightness", .{ "backlight", name, value });
}

pub fn setBrightnessPercent(this: *Backlight, name: []const u8, percent: u8) !void {
    var info = try this.getBacklight(name);
    defer info.deinit(this.allocator);

    const clamped: u32 = @min(percent, 100);
    const value: u32 = @intCast(@as(u64, info.max_brightness) * clamped / 100);

    try this.setBrightness(name, value);
}

pub fn increaseBrightness(this: *Backlight, name: []const u8, step: u8) !void {
    var info = try this.getBacklight(name);
    defer info.deinit(this.allocator);

    const new_percent = info.percentage +| step;
    try this.setBrightnessPercent(name, @min(new_percent, 100));
}

pub fn decreaseBrightness(this: *Backlight, name: []const u8, step: u8) !void {
    var info = try this.getBacklight(name);
    defer info.deinit(this.allocator);

    const new_percent = info.percentage -| step;
    try this.setBrightnessPercent(name, new_percent);
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

test "percentage calculation" {
    try testing.expectEqual(@as(u8, 50), @as(u8, @intCast(@min(@as(u64, 50) * 100 / @as(u64, 100), 100))));
    try testing.expectEqual(@as(u8, 100), @as(u8, @intCast(@min(@as(u64, 255) * 100 / @as(u64, 255), 100))));
    try testing.expectEqual(@as(u8, 0), @as(u8, @intCast(@min(@as(u64, 0) * 100 / @as(u64, 100), 100))));
}
