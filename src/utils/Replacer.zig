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

/// Applies replacements to a template, supporting typed values and formatting.
const Replacer = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Io = std.Io;
const Writer = Io.Writer;
const fmt = std.fmt;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;

/// Memory allocator used for all internal allocations.
allocator: Allocator,
/// Typed values available for templating. Keys and string values are
/// duplicated and owned by this allocator.
values: StringHashMap(Value),
/// Legacy byte-sequence replacement rules applied after template processing.
replacements: ArrayList(Replacement) = .empty,
/// List for tracking strings produced and returned by render().
rendered_strings: ArrayList([]const u8) = .empty,
/// When true, render() returns PlaceholderNotFound for missing keys.
/// When false (default), unmatched placeholders are passed through unchanged.
strict: bool = false,

pub const ReplacerError = error{
    PlaceholderNotFound,
};

/// A value that can be formatted in a template.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

/// A legacy byte-sequence replacement rule.
const Replacement = struct {
    /// The substring to match.
    from: []const u8,
    /// The replacement substring.
    to: []const u8,
    /// Whether the strings are owned and need to be freed.
    owned: bool,
};

pub inline fn init(allocator: Allocator) Replacer {
    return .{ .allocator = allocator, .values = .init(allocator) };
}

/// Frees all owned memory and releases internal container buffers.
/// Must be called when the Replacer is no longer needed.
pub fn deinit(this: *Replacer) void {
    var key_it = this.values.keyIterator();
    while (key_it.next()) |key| this.allocator.free(key.*);

    var val_it = this.values.valueIterator();
    while (val_it.next()) |v| {
        if (v.* == .string) this.allocator.free(v.string);
    }

    this.values.deinit();

    for (this.replacements.items) |r| {
        if (r.owned) {
            this.allocator.free(r.from);
            this.allocator.free(r.to);
        }
    }
    this.replacements.deinit(this.allocator);

    for (this.rendered_strings.items) |str| this.allocator.free(str);
    this.rendered_strings.deinit(this.allocator);
}

/// Frees all owned string allocations and clears entries while retaining
/// container capacity for reuse.
pub fn clear(this: *Replacer) void {
    var key_it = this.values.keyIterator();
    while (key_it.next()) |key| this.allocator.free(key.*);

    var val_it = this.values.valueIterator();
    while (val_it.next()) |v| {
        if (v.* == .string) this.allocator.free(v.string);
    }

    for (this.replacements.items) |r| {
        if (r.owned) {
            this.allocator.free(r.from);
            this.allocator.free(r.to);
        }
    }
    this.replacements.clearRetainingCapacity();

    for (this.rendered_strings.items) |str| this.allocator.free(str);
    this.rendered_strings.clearRetainingCapacity();

    this.values.clearRetainingCapacity();
}

pub inline fn setStrict(this: *Replacer, enabled: bool) void {
    this.strict = enabled;
}

/// Adds a legacy replacement rule using borrowed (non-owned) slices.
/// The caller must ensure the slices outlive this Replacer.
pub fn add(this: *Replacer, from: []const u8, to: []const u8) !void {
    try this.replacements.append(this.allocator, .{ .from = from, .to = to, .owned = false });
}

/// Adds a string key-value pair. Both key and value are duplicated.
pub fn addKey(this: *Replacer, key: []const u8, value: []const u8) !void {
    const key_owned = try this.allocator.dupe(u8, key);
    errdefer this.allocator.free(key_owned);

    const val_owned = try this.allocator.dupe(u8, value);
    errdefer this.allocator.free(val_owned);

    if (try this.values.fetchPut(key_owned, .{ .string = val_owned })) |old| {
        this.allocator.free(old.key);

        if (old.value == .string) this.allocator.free(old.value.string);
    }
}

/// Adds a key-value pair with automatic type detection.
/// Supports integers, floats, booleans, and strings.
pub fn addKeyAny(this: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    // Integers
    if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        const k = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(k);
        try this.values.put(k, .{ .integer = @intCast(value) });
        return;
    }

    // Floats
    if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) {
        const k = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(k);
        try this.values.put(k, .{ .float = @floatCast(value) });
        return;
    }

    // Bool
    if (T == bool) {
        const k = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(k);
        try this.values.put(k, .{ .boolean = value });
        return;
    }

    // Strings (Slice or Array Ptr)
    const is_string = T == []const u8 or T == []u8 or (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size != .slice);
    if (is_string) {
        try this.addKey(key, @as([]const u8, value));
        return;
    }

    // Fallback: format to string then store via addKey so ownership is correct
    const str = try fmt.allocPrint(this.allocator, "{any}", .{value});
    defer this.allocator.free(str);
    try this.addKey(key, str);
}

/// Renders the template, substituting `{key}` and `{key:fmt}` placeholders.
/// The returned slice is allocated with this.allocator and must be freed by
/// the caller (or reclaimed via arena teardown).
pub fn render(this: *Replacer, template: []const u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(this.allocator);

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];

        if (c != '{') {
            try result.append(this.allocator, c);
            i += 1;
            continue;
        }

        // Escaped {{
        if (i + 1 < template.len and template[i + 1] == '{') {
            try result.append(this.allocator, '{');
            i += 2;
            continue;
        }

        const remaining = template[i + 1 ..];
        const end_offset = mem.findScalar(u8, remaining, '}') orelse {
            try result.append(this.allocator, c);
            i += 1;
            continue;
        };

        const content = remaining[0..end_offset];
        const full_len = end_offset + 2; // '{' + content + '}'

        var key_part = content;
        var fmt_part: ?[]const u8 = null;

        if (mem.findScalar(u8, content, ':')) |colon_idx| {
            key_part = content[0..colon_idx];
            fmt_part = content[colon_idx + 1 ..];
        }

        if (this.values.get(key_part)) |val| {
            try renderValue(this.allocator, &result, val, fmt_part);
            i += full_len;
            continue;
        }

        if (this.strict) return ReplacerError.PlaceholderNotFound;

        try result.append(this.allocator, c);
        i += 1;
    }

    if (this.replacements.items.len == 0) {
        const out = try result.toOwnedSlice(this.allocator);
        errdefer this.allocator.free(out);
        try this.rendered_strings.append(this.allocator, out);
        return out;
    }

    // Legacy pass: apply string-replace rules, freeing each intermediate slice.
    var out = try result.toOwnedSlice(this.allocator);
    errdefer this.allocator.free(out);
    for (this.replacements.items) |r| {
        const replaced = try mem.replaceOwned(u8, this.allocator, out, r.from, r.to);
        this.allocator.free(out);
        out = replaced;
    }

    try this.rendered_strings.append(this.allocator, out);
    return out;
}

/// Formats a byte count with an appropriate unit suffix (B, KiB, MiB, …).
fn formatBytes(w: anytype, bytes: i64, precision: usize) !void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var size: f64 = @floatFromInt(if (bytes < 0) -bytes else bytes);
    var unit_idx: usize = 0;

    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }

    if (bytes < 0) size = -size;

    const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
    const rounded = @round(size * multiplier) / multiplier;

    if (@trunc(rounded) == rounded) {
        try w.print("{d}{s}", .{ @as(i64, @intFromFloat(rounded)), units[unit_idx] });
    } else {
        try w.print("{d:.[1]}", .{ size, precision });
        try w.writeAll(units[unit_idx]);
    }
}

/// Formats a byte-per-second value with appropriate unit suffix (B/s, KB/s, etc.).
/// Handles negative values and configurable decimal precision.
fn formatSpeed(w: anytype, bytes_per_sec: f64, precision: usize) !void {
    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s" };
    var size: f64 = if (bytes_per_sec < 0) -bytes_per_sec else bytes_per_sec;
    var unit_idx: usize = 0;

    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }

    if (bytes_per_sec < 0) size = -size;

    const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
    const rounded = @round(size * multiplier) / multiplier;

    if (@trunc(rounded) == rounded) {
        try w.print("{d}{s}", .{ @as(i64, @intFromFloat(rounded)), units[unit_idx] });
    } else {
        try w.print("{d:.[1]}", .{ size, precision });
        try w.writeAll(units[unit_idx]);
    }
}

/// Renders a Value to the output writer with optional format specifier.
/// Format specifiers:
///   - `.N` for integers: format as bytes with N decimal precision
///   - `^N` for floats: format as speed with N decimal precision
///   - `N` for width: zero-padded integers
///   - bare number: decimal precision for floats
fn renderValue(allocator: Allocator, out: *ArrayList(u8), val: Value, fmt_spec: ?[]const u8) !void {
    var aw: Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();

    const w = &aw.writer;
    switch (val) {
        .string => |s| try w.writeAll(s),
        .integer => |d| {
            const spec = fmt_spec orelse {
                try w.print("{d}", .{d});
                return;
            };

            if (spec.len > 0 and spec[0] == '.') {
                const precision = fmt.parseInt(usize, spec[1..], 10) catch 2;
                try formatBytes(w, d, precision);
            } else if (fmt.parseInt(usize, spec, 10)) |width| {
                if (d >= 0) {
                    try w.print("{d:0>[1]}", .{ @as(u64, @intCast(d)), width });
                } else {
                    try w.print("{d:0>[1]}", .{ d, width });
                }
            } else |_| try w.print("{d}", .{d});
        },
        .float => |f| {
            const spec = fmt_spec orelse {
                try w.print("{d}", .{f});
                return;
            };

            if (spec.len > 0 and spec[0] == '^') {
                const precision = fmt.parseInt(usize, spec[1..], 10) catch 1;
                try formatSpeed(w, f, precision);
            } else if (fmt.parseInt(usize, spec, 10)) |precision| {
                const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
                const rounded = @round(f * multiplier) / multiplier;
                if (@trunc(rounded) == rounded) {
                    try w.print("{d}", .{@as(i64, @intFromFloat(rounded))});
                } else {
                    try w.print("{d:.[1]}", .{ f, precision });
                }
            } else |_| try w.print("{d}", .{f});
        },
        .boolean => |b| try w.print("{}", .{b}),
    }
}
