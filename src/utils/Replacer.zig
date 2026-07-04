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

/// Applies typed value substitution and byte-sequence replacements to templates.
const Replacer = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Io = std.Io;
const Writer = Io.Writer;
const fmt = std.fmt;
const ascii = std.ascii;
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const ReplacerError = error{
    PlaceholderNotFound,
};

/// A typed value that can be substituted into a template placeholder.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
};

/// Measurement unit system used for formatting byte counts and transfer speeds.
pub const Units = enum {
    binary,
    decimal,

    const DECIMAL_BASE: f64 = 1000.0;
    const BINARY_BASE: f64 = 1024.0;

    const DECIMAL_BYTE_UNITS = [_][]const u8{ "B", "KB", "MB", "GB", "TB", "PB" };
    const DECIMAL_SPEED_UNITS = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s" };

    const BINARY_BYTE_UNITS = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    const BINARY_SPEED_UNITS = [_][]const u8{ "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s", "PiB/s" };

    pub fn base(this: @This()) f64 {
        return switch (this) {
            .binary => BINARY_BASE,
            .decimal => DECIMAL_BASE,
        };
    }

    pub fn byteUnits(this: @This()) []const []const u8 {
        return switch (this) {
            .binary => &BINARY_BYTE_UNITS,
            .decimal => &DECIMAL_BYTE_UNITS,
        };
    }

    pub fn speedUnits(this: @This()) []const []const u8 {
        return switch (this) {
            .binary => &BINARY_SPEED_UNITS,
            .decimal => &DECIMAL_SPEED_UNITS,
        };
    }
};

allocator: Allocator,
values: StringHashMap(Value),
/// When true, render() returns PlaceholderNotFound for any unresolved key.
/// When false (default), unresolved placeholders are passed through unchanged.
strict: bool = false,

pub fn init(allocator: Allocator) Replacer {
    return .{ .allocator = allocator, .values = .init(allocator) };
}

/// Releases all owned memory. Must be called exactly once when done.
pub fn deinit(this: *Replacer) void {
    this.freeValues();
    this.values.deinit();
}

/// Frees all owned data and clears internal state while retaining capacity.
pub fn clear(this: *Replacer) void {
    this.freeValues();
    this.values.clearRetainingCapacity();
}

pub fn free(this: *Replacer, memory: anytype) void {
    this.allocator.free(memory);
}

pub inline fn setStrict(this: *Replacer, enabled: bool) void {
    this.strict = enabled;
}

/// Associates `key` with a string value. Both are duplicated internally.
pub fn addKey(this: *Replacer, key: []const u8, value: []const u8) !void {
    const val_owned = try this.allocator.dupe(u8, value);
    errdefer this.free(val_owned);
    try this.putValue(key, .{ .string = val_owned });
}

/// Associates `key` with a typed value inferred from `value`'s comptime type.
pub fn addKeyAny(this: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    if (info == .int or info == .comptime_int) {
        return this.putValue(key, .{ .integer = @intCast(value) });
    }

    if (info == .float or info == .comptime_float) {
        return this.putValue(key, .{ .float = @floatCast(value) });
    }

    if (T == bool) {
        return this.putValue(key, .{ .boolean = value });
    }

    if (T == []const u8 or T == []u8) {
        return this.addKey(key, value);
    }

    if (info == .pointer and info.pointer.size == .many) {
        return this.addKey(key, mem.span(value));
    }

    // Fallback: format to a temporary string.
    const str = try fmt.allocPrint(this.allocator, "{any}", .{value});
    defer this.free(str);
    return this.addKey(key, str);
}

/// Renders `template` into `writer`, substituting `{key}`, `{key:spec}`, and chained sequences.
///
/// Format specifiers:
///   - `{key:.N}` — integer formatted as bytes with N decimal places (binary units)
///   - `{key:^N}` — float formatted as transfer speed with N decimal places (decimal units)
///   - `{key*N}`  — string repeated N times
///   - `{key:N}`  — zero-padded integer (width N) or rounded float (N decimal places)
///
/// Variable Chaining & Literals:
///   - `{key:anotherkey:yet_another}` — evaluates and joins multiple global placeholders sequentially.
///   - `{key:spec:'string_literal'}` — appends a literal raw string immediately after evaluation.
pub fn render(this: *const Replacer, template: []const u8) ![]u8 {
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

        // Escaped `{{` → literal `{`.
        if (i + 1 < template.len and template[i + 1] == '{') {
            try result.append(this.allocator, '{');
            i += 2;
            continue;
        }

        const rest = template[i + 1 ..];
        const close = mem.findScalar(u8, rest, '}') orelse {
            try result.append(this.allocator, c);
            i += 1;
            continue;
        };

        const content = rest[0..close];
        
        var parts = mem.splitScalar(u8, content, ':');
        var current_key: ?[]const u8 = null;
        var current_spec: ?[]const u8 = null;
        var is_first = true;
        var first_key_found = false;

        while (parts.next()) |token| {
            if (is_first) {
                current_key = token;
                is_first = false;

                if (mem.findScalar(u8, token, '*')) |star| {
                    if (star > 0) {
                        current_key = token[0..star];
                        current_spec = token[star..];
                    }
                }

                if (this.values.get(current_key.?)) |_| {
                    first_key_found = true;
                } else {
                    break;
                }
            } else {
                if (isFormatSpec(token)) {
                    current_spec = token;
                } else if (token.len >= 2 and token[0] == '\'' and token[token.len - 1] == '\'') {
                    if (current_key) |k| {
                        if (this.values.get(k)) |val| {
                            try appendValue(this.allocator, &result, val, current_spec);
                        } else if (this.strict) {
                            return ReplacerError.PlaceholderNotFound;
                        }
                    }
                    try result.appendSlice(this.allocator, token[1 .. token.len - 1]);
                    current_key = null;
                    current_spec = null;
                } else {
                    if (current_key) |k| {
                        if (this.values.get(k)) |val| {
                            try appendValue(this.allocator, &result, val, current_spec);
                        } else if (this.strict) {
                            return ReplacerError.PlaceholderNotFound;
                        }
                    }
                    current_key = token;
                    current_spec = null;
                }
            }
        }

        if (first_key_found) {
            if (current_key) |k| {
                if (this.values.get(k)) |val| {
                    try appendValue(this.allocator, &result, val, current_spec);
                } else if (this.strict) {
                    return ReplacerError.PlaceholderNotFound;
                }
            }
            i += close + 2; // '{' + content + '}'
            continue;
        }

        if (this.strict) return ReplacerError.PlaceholderNotFound;

        try result.append(this.allocator, c);
        i += close + 2;
    }

    return try result.toOwnedSlice(this.allocator);
}

/// Registers common escape-sequence placeholders available to all modules.
///
/// Placeholders: `{newline}` `{nl}` `{tab}` `{dot}` `{pipe}`
pub fn addCommonPlaceholders(this: *Replacer) !void {
    try this.addKey("newline", "\n");
    try this.addKey("nl", "\n");
    try this.addKey("tab", "\t");
    try this.addKey("dot", "·");
    try this.addKey("pipe", "|");
}

/// Writes `bytes` as a human-readable size string using the given unit system.
pub fn formatBytes(writer: *Writer, bytes: i64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, @floatFromInt(bytes), precision, system.base(), system.byteUnits());
}

/// Writes `bytes_per_sec` as a human-readable speed string using the given unit system.
pub fn formatSpeed(writer: *Writer, bytes_per_sec: f64, precision: usize, system: Units) !void {
    try scaleAndWrite(writer, bytes_per_sec, precision, system.base(), system.speedUnits());
}

fn freeValues(this: *Replacer) void {
    var it = this.values.iterator();
    while (it.next()) |e| {
        this.free(e.key_ptr.*);
        if (e.value_ptr.* == .string) this.free(e.value_ptr.string);
    }
}

/// Inserts or replaces a value, freeing any previously-owned string.
fn putValue(this: *Replacer, key: []const u8, value: Value) !void {
    const gop = try this.values.getOrPut(key);

    if (gop.found_existing) {
        if (gop.value_ptr.* == .string) this.free(gop.value_ptr.string);
        gop.value_ptr.* = value;
        return;
    }

    gop.key_ptr.* = this.allocator.dupe(u8, key) catch |err| {
        _ = this.values.remove(key);
        return err;
    };

    gop.value_ptr.* = value;
}

/// Returns true if `s` matches a known format-spec token (`.N`, `^N`, `*N`, or a bare width `N`).
fn isFormatSpec(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '.' or s[0] == '^' or s[0] == '*') return true;

    for (s) |c| {
        if (!ascii.isDigit(c)) return false;
    }

    return true;
}

/// Scales `value` down through `units` by repeatedly dividing by `base`,
/// then writes the result with the appropriate suffix.
fn scaleAndWrite(writer: *Writer, value: f64, precision: usize, base: f64, units: []const []const u8) !void {
    const negative = value < 0;
    var size: f64 = @abs(value);
    var idx: usize = 0;

    while (size >= base and idx < units.len - 1) {
        size /= base;
        idx += 1;
    }

    if (negative) size = -size;

    const rounded = roundTo(size, precision);

    if (@trunc(rounded) == rounded) {
        try writer.print("{d}{s}", .{ @as(i64, @intFromFloat(rounded)), units[idx] });
    } else {
        try writer.print("{d:.[1]}", .{ size, precision });
        try writer.writeAll(units[idx]);
    }
}

/// Rounds `v` to `precision` decimal places.
inline fn roundTo(v: f64, precision: usize) f64 {
    const m = math.pow(f64, 10.0, @floatFromInt(precision));
    return @round(v * m) / m;
}

/// Appends the formatted representation of `val` to `buffer`.
fn appendValue(allocator: Allocator, buffer: *ArrayList(u8), val: Value, spec: ?[]const u8) !void {
    var aw: Writer.Allocating = .fromArrayList(allocator, buffer);
    defer buffer.* = aw.toArrayList();

    const writer = &aw.writer;

    switch (val) {
        .string => |s| try appendString(writer, s, spec),
        .integer => |d| try appendInteger(writer, d, spec),
        .float => |f| try appendFloat(writer, f, spec),
        .boolean => |b| try writer.print("{}", .{b}),
    }
}

fn appendString(writer: *Writer, s: []const u8, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.writeAll(s);

    if (sp.len > 0 and sp[0] == '*') {
        const count = fmt.parseInt(usize, sp[1..], 10) catch 1;
        for (0..count) |_| try writer.writeAll(s);
        return;
    }

    try writer.writeAll(s);
}

fn appendInteger(writer: *Writer, d: i64, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.print("{d}", .{d});

    if (sp.len > 0 and sp[0] == '.') {
        const precision = fmt.parseInt(usize, sp[1..], 10) catch 2;
        return formatBytes(writer, d, precision, .binary);
    }

    if (fmt.parseInt(usize, sp, 10)) |width| {
        if (d >= 0) {
            return writer.print("{d:0>[1]}", .{ @as(u64, @intCast(d)), width });
        }

        return writer.print("{d:0>[1]}", .{ d, width });
    } else |_| {}

    try writer.print("{d}", .{d});
}

fn appendFloat(writer: *Writer, f: f64, spec: ?[]const u8) !void {
    const sp = spec orelse return writer.print("{d}", .{f});

    if (sp.len > 0 and sp[0] == '^') {
        const precision = fmt.parseInt(usize, sp[1..], 10) catch 1;
        return formatSpeed(writer, f, precision, .decimal);
    }

    if (fmt.parseInt(usize, sp, 10)) |precision| {
        const rounded = roundTo(f, precision);
        if (@trunc(rounded) == rounded) {
            return writer.print("{d}", .{@as(i64, @intFromFloat(rounded))});
        }

        return writer.print("{d:.[1]}", .{ f, precision });
    } else |_| {}

    try writer.print("{d}", .{f});
}