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

/// Reads Linux memory statistics and exposes formatted usage information.
const Module = @This();

const std = @import("std");
const core = @import("core");
const StaticStringMap = std.StaticStringMap;
const Io = std.Io;
const Duration = Io.Duration;
const mem = std.mem;
const Allocator = mem.Allocator;
const math = std.math;
const fmt = std.fmt;

io: Io,
allocator: Allocator,
writer: *Io.Writer,
config: Config = .{},
memory_info: MemoryInfo = .{},

pub const Config = struct {
    update_interval: i64 = 1,
    icon: []const u8 = "",
    text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

const PhysicalMemoryInfo = struct {
    available: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    free: u64 = 0,
    shared: u64 = 0,
    total: u64 = 0,
    used: u64 = 0,
};

const SwapMemoryInfo = struct {
    cached: u64 = 0,
    free: u64 = 0,
    total: u64 = 0,
    used: u64 = 0,
};

const MemoryInfo = struct {
    physical: PhysicalMemoryInfo = .{},
    swap: SwapMemoryInfo = .{},
};

const Key = enum {
    MemTotal,
    MemFree,
    MemAvailable,
    Buffers,
    Cached,
    Shmem,
    SwapTotal,
    SwapFree,
    SwapCached,
};

const key_map = StaticStringMap(Key).initComptime(.{
    .{ "MemTotal", .MemTotal },
    .{ "MemFree", .MemFree },
    .{ "MemAvailable", .MemAvailable },
    .{ "Buffers", .Buffers },
    .{ "Cached", .Cached },
    .{ "Shmem", .Shmem },
    .{ "SwapTotal", .SwapTotal },
    .{ "SwapFree", .SwapFree },
    .{ "SwapCached", .SwapCached },
});

pub fn init(io: Io, allocator: Allocator, writer: *Io.Writer, config: Config) Module {
    return .{ .io = io, .allocator = allocator, .writer = writer, .config = config };
}

inline fn parseValue(this: *Module, s: []const u8) !u64 {
    _ = this;

    var it = mem.tokenizeAny(u8, s, " \t");
    const num_str = it.next() orelse return error.Invalid;
    const unit = it.next() orelse return error.Invalid;

    if (!mem.eql(u8, unit, "kB")) return error.Invalid;

    const value = try fmt.parseUnsigned(u64, num_str, 10);
    return math.mul(u64, value, 1024);
}

pub inline fn execute(this: *Module, json_builder: *core.json) !void {
    var buffer: [4096]u8 = undefined;
    var slices: [1][]u8 = .{buffer[0..]};

    var file = try Io.Dir.openFileAbsolute(this.io, "/proc/meminfo", .{ .mode = .read_only });
    defer file.close(this.io);

    const bytes_read = try file.readStreaming(this.io, slices[0..]);

    var percentage: u64 = 0;

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const key_str = line[0..colon];
        const rest = mem.trimStart(u8, line[colon + 1 ..], " \t");

        const which = key_map.get(key_str) orelse continue;
        const value = try this.parseValue(rest);

        switch (which) {
            .MemTotal => this.memory_info.physical.total = value,
            .MemFree => this.memory_info.physical.free = value,
            .MemAvailable => this.memory_info.physical.available = value,
            .Buffers => this.memory_info.physical.buffers = value,
            .Cached => this.memory_info.physical.cached = value,
            .Shmem => this.memory_info.physical.shared = value,
            .SwapTotal => this.memory_info.swap.total = value,
            .SwapFree => this.memory_info.swap.free = value,
            .SwapCached => this.memory_info.swap.cached = value,
        }
    }

    // Fallback for older kernels without MemAvailable
    if (this.memory_info.physical.available == 0 and this.memory_info.physical.total != 0) {
        const freeish = this.memory_info.physical.free + this.memory_info.physical.buffers + this.memory_info.physical.cached;
        this.memory_info.physical.available = @min(freeish, this.memory_info.physical.total);
    }

    if (this.memory_info.physical.total >= this.memory_info.physical.available) this.memory_info.physical.used = this.memory_info.physical.total - this.memory_info.physical.available;
    if (this.memory_info.swap.total >= this.memory_info.swap.free) this.memory_info.swap.used = this.memory_info.swap.total - this.memory_info.swap.free;

    const total_usage = this.memory_info.physical.used + this.memory_info.swap.used;
    const total_memory = this.memory_info.physical.total + this.memory_info.swap.total;

    if (total_memory != 0) percentage = @intFromFloat((@as(f64, @floatFromInt(total_usage)) / @as(f64, @floatFromInt(total_memory))) * 100.0);

    // Build default text and tooltip
    var default_text_buf: [256]u8 = undefined;
    const default_text = fmt.bufPrint(&default_text_buf, "{s} {d}% · {Bi:.2}", .{ this.config.icon, percentage, total_usage }) catch "";

    var default_tooltip_buf: [2048]u8 = undefined;
    const default_tooltip = fmt.bufPrint(&default_tooltip_buf, "Physical Memory\nTotal · {Bi:.2}\nUsed · {Bi:.2}\nFree · {Bi:.2}\nAvailable · {Bi:.2}\nShared · {Bi:.2}\nBuffers · {Bi:.2}\nCached · {Bi:.2}\n\nSwap Memory\nTotal · {Bi:.2}\nUsed · {Bi:.2}\nFree · {Bi:.2}\nCached · {Bi:.2}", .{
        this.memory_info.physical.total,
        this.memory_info.physical.used,
        this.memory_info.physical.free,
        this.memory_info.physical.available,
        this.memory_info.physical.shared,
        this.memory_info.physical.buffers,
        this.memory_info.physical.cached,
        this.memory_info.swap.total,
        this.memory_info.swap.used,
        this.memory_info.swap.free,
        this.memory_info.swap.cached,
    }) catch "";

    // Use custom templates if provided
    if (this.config.text != null or this.config.tooltip != null) {
        var replacer = core.Replacer.init(this.allocator);
        defer replacer.deinit();

        try core.output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", this.config.icon);
        try replacer.addKeyAny("usage_percent", percentage);
        try replacer.addKeyAny("total_usage", total_usage);
        try replacer.addKeyAny("mem_total", this.memory_info.physical.total);
        try replacer.addKeyAny("mem_used", this.memory_info.physical.used);
        try replacer.addKeyAny("mem_free", this.memory_info.physical.free);
        try replacer.addKeyAny("mem_available", this.memory_info.physical.available);
        try replacer.addKeyAny("mem_shared", this.memory_info.physical.shared);
        try replacer.addKeyAny("mem_buffers", this.memory_info.physical.buffers);
        try replacer.addKeyAny("mem_cached", this.memory_info.physical.cached);
        try replacer.addKeyAny("swap_total", this.memory_info.swap.total);
        try replacer.addKeyAny("swap_used", this.memory_info.swap.used);
        try replacer.addKeyAny("swap_free", this.memory_info.swap.free);
        try replacer.addKeyAny("swap_cached", this.memory_info.swap.cached);

        try core.output.renderText(json_builder, &replacer, this.config.text, default_text);
        try core.output.renderTooltip(json_builder, &replacer, this.config.tooltip, default_tooltip);
    } else {
        try json_builder.set("text", default_text);
        try json_builder.set("tooltip", default_tooltip);
    }

    try json_builder.write(this.writer);
}
