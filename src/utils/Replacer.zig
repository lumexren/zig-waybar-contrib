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

/// Memory allocator used for duplicating strings and managing internal storage.
allocator: Allocator,
/// Typed values available for templating. Keys are duplicated and owned by the Replacer.
/// Supported value types: string, integer, float, boolean.
values: StringHashMap(Value),
/// Legacy byte-sequence replacement rules (applied after template processing).
/// These are simpler string substitutions without formatting support.
/// Prefer using values for most use cases; replacements exist for compatibility.
replacements: ArrayList(Replacement) = .empty,
/// When true, causes `render()` to return `PlaceholderNotFound` for missing keys.
/// When false (default), unmatched placeholders are passed through unchanged.
strict: bool = false,

pub const ReplacerError = error{
    PlaceholderNotFound,
};

/// Represents a value that can be formatted in a template.
/// Supports string, integer, float, and boolean types with optional format specifiers.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

/// Represents a legacy byte-sequence replacement rule.
/// Applied as simple string substitution after template processing.
const Replacement = struct {
    /// The substring to match.
    from: []const u8,
    /// The replacement substring.
    to: []const u8,
    /// Whether the strings are owned and need to be freed.
    owned: bool,
};

/// Initializes a Replacer with the given allocator.
/// The Allocator is stored for later string duplication in addKey/addKeyAny.
pub inline fn init(allocator: Allocator) Replacer {
    return .{ .allocator = allocator, .values = .init(allocator) };
}

/// Frees all owned replacement data and internal storage.
/// Must be called when the Replacer is no longer needed.
pub fn deinit(this: *Replacer) void {
    // Free keys in the map since they are duplicated/owned
    var it = this.values.keyIterator();
    while (it.next()) |key| this.allocator.free(key.*);

    // Free string values in the map (integers don't need free)
    var val_it = this.values.valueIterator();
    while (val_it.next()) |v| {
        switch (v.*) {
            .string => |s| this.allocator.free(s),
            else => {},
        }
    }

    this.values.deinit();

    // Free legacy replacements
    for (this.replacements.items) |r| {
        if (r.owned) {
            this.allocator.free(r.from);
            this.allocator.free(r.to);
        }
    }
    this.replacements.deinit(this.allocator);
}

/// Removes all replacements while retaining allocated capacity.
/// Frees all owned string memory but keeps internal buffers for reuse.
pub fn clear(this: *Replacer) void {
    var it = this.values.keyIterator();
    while (it.next()) |key| this.allocator.free(key.*);

    var val_it = this.values.valueIterator();
    while (val_it.next()) |v| {
        switch (v.*) {
            .string => |s| this.allocator.free(s),
            else => {},
        }
    }

    this.values.clearRetainingCapacity();

    // Clean legacy replacements
    for (this.replacements.items) |r| {
        if (r.owned) {
            this.allocator.free(r.from);
            this.allocator.free(r.to);
        }
    }

    this.replacements.clearRetainingCapacity();
}

/// Sets strict mode for placeholder resolution.
/// When enabled, render() returns PlaceholderNotFound for undefined keys.
pub inline fn setStrict(this: *Replacer, enabled: bool) void {
    this.strict = enabled;
}

/// Adds a legacy replacement rule using borrowed slices.
/// The strings are NOT duplicated; the Replacer does not own them.
/// Prefer addKey/addKeyAny for typed value templates instead.
pub fn add(this: *Replacer, from: []const u8, to: []const u8) !void {
    try this.replacements.append(this.allocator, .{ .from = from, .to = to, .owned = false });
}

/// Adds a key-value pair.
/// The key and string values are duplicated and owned by the Replacer.
pub fn addKey(this: *Replacer, key: []const u8, value: []const u8) !void {
    const key_owned = try this.allocator.dupe(u8, key);
    errdefer this.allocator.free(key_owned);

    const val_owned = try this.allocator.dupe(u8, value);
    errdefer this.allocator.free(val_owned);

    try this.values.put(key_owned, .{ .string = val_owned });
}

/// Adds a key-value pair detecting the type.
/// Supports integers, floats, booleans, and strings.
pub fn addKeyAny(this: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    // Integers
    if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
        const key_owned = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(key_owned);
        try this.values.put(key_owned, .{ .integer = @intCast(value) });
        return;
    }

    // Floats
    if (@typeInfo(T) == .float or @typeInfo(T) == .comptime_float) {
        const key_owned = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(key_owned);
        try this.values.put(key_owned, .{ .float = @floatCast(value) });
        return;
    }

    // Bool
    if (T == bool) {
        const key_owned = try this.allocator.dupe(u8, key);
        errdefer this.allocator.free(key_owned);
        try this.values.put(key_owned, .{ .boolean = value });
        return;
    }

    // Strings (Slice or Array Ptr)
    const is_string = T == []const u8 or T == []u8 or (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size != .slice);
    if (is_string) {
        // Assume string-like
        const slice: []const u8 = value;
        try this.addKey(key, slice);
        return;
    }

    // Fallback: Format to string
    const str = try fmt.allocPrint(this.allocator, "{any}", .{value});
    // addKey takes ownership of the string duplication, so we pass this temp string.
    // However, addKey dupes it again. Ideally we optimized, but for safety lets rely on addKey behavior.
    // Wait, addKey dupes, so we need to free `str` after.
    defer this.allocator.free(str);
    try this.addKey(key, str);
}

/// Renders the template with formatting support.
///
/// Scans for `{key}` or `{key:fmt}` sequences.
pub fn render(this: *Replacer, template: []const u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(this.allocator);

    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];

        if (c == '{') {
            // Potential placeholder start
            if (i + 1 < template.len and template[i + 1] == '{') {
                // Escaped {{
                try result.append(this.allocator, '{');
                i += 2;
                continue;
            }

            // Find closing '}'
            const remaining = template[i + 1 ..];
            if (mem.findScalar(u8, remaining, '}')) |end_offset| {
                const full_len = end_offset + 2; // +1 for '{', +1 for '}'
                const content = remaining[0..end_offset];

                // Parse content: key[:fmt]
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

                // Not found within values? Check strict mode
                if (this.strict) return ReplacerError.PlaceholderNotFound;
            }
        }

        try result.append(this.allocator, c);
        i += 1;
    }

    // Legacy pass: Apply string-replace rules on the result
    if (this.replacements.items.len > 0) {
        var legacy_res = try result.toOwnedSlice(this.allocator);
        errdefer this.allocator.free(legacy_res);

        for (this.replacements.items) |r| {
            const new_res = try mem.replaceOwned(u8, this.allocator, legacy_res, r.from, r.to);
            this.allocator.free(legacy_res);
            legacy_res = new_res;
        }

        return legacy_res;
    }

    return result.toOwnedSlice(this.allocator);
}

/// Formats a byte count with appropriate unit suffix (B, KiB, MiB, etc.).
/// Handles negative values and configurable decimal precision.
fn formatBytes(w: anytype, bytes: i64, precision: usize) !void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var size: f64 = @floatFromInt(if (bytes < 0) -bytes else bytes);
    var unit_idx: usize = 0;

    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }

    if (bytes < 0) size = -size;

    // Check if result is whole number after rounding
    const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
    const rounded = @round(size * multiplier) / multiplier;
    const is_whole = @trunc(rounded) == rounded;

    if (is_whole) {
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

    // Check if result is whole number after rounding
    const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
    const rounded = @round(size * multiplier) / multiplier;
    const is_whole = @trunc(rounded) == rounded;

    if (is_whole) {
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
            if (fmt_spec) |spec| {
                // Check for byte formatting: .N means format as bytes with N precision
                if (spec.len > 0 and spec[0] == '.') {
                    const precision = fmt.parseInt(usize, spec[1..], 10) catch 2;
                    try formatBytes(w, d, precision);
                } else if (fmt.parseInt(usize, spec, 10)) |width| {
                    // Always zero-pad if a simple integer width is provided
                    if (d >= 0) {
                        const ud = @as(u64, @intCast(d));
                        try w.print("{d:0>[1]}", .{ ud, width });
                    } else try w.print("{d:0>[1]}", .{ d, width });
                } else |_| try w.print("{d}", .{d});
            } else try w.print("{d}", .{d});
        },
        .float => |f| {
            if (fmt_spec) |spec| {
                // Check for speed formatting: ^N means format as speed with N precision
                if (spec.len > 0 and spec[0] == '^') {
                    const precision = fmt.parseInt(usize, spec[1..], 10) catch 1;
                    try formatSpeed(w, f, precision);
                } else if (fmt.parseInt(usize, spec, 10)) |precision| {
                    const multiplier = math.pow(f64, 10.0, @floatFromInt(precision));
                    const rounded = @round(f * multiplier) / multiplier;
                    const is_whole = @trunc(rounded) == rounded;
                    if (is_whole) {
                        try w.print("{d}", .{@as(i64, @intFromFloat(rounded))});
                    } else try w.print("{d:.[1]}", .{ f, precision });
                } else |_| try w.print("{d}", .{f});
            } else try w.print("{d}", .{f});
        },
        .boolean => |b| try w.print("{}", .{b}),
    }
}
