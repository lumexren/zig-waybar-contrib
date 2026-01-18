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

/// An incremental JSON object builder with explicit memory management.
///
/// This type allows constructing JSON objects dynamically while
/// maintaining predictable allocation behavior via a user-provided allocator.
const JsonBuilder = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;

allocator: Allocator,
fields: ArrayList(Field) = .empty,
counter: u64 = 0,

/// Represents a JSON value supported by the builder.
///
/// Only a minimal subset of JSON types is supported:
/// - `string`  → JSON string
/// - `number`  → JSON integer number
/// - `boolean` → JSON boolean
///
/// This restricted set is intentional and matches the needs of
/// lightweight, streaming JSON generation scenarios.
pub const Value = union(enum) {
    string: []const u8,
    number: i64,
    boolean: bool,
};

/// Represents a single key-value pair in a JSON object.
///
/// The `key` is written as a JSON string, and the associated `value`
/// is serialized according to its `Value` variant.
pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// Initializes a new JSON builder using the given allocator.
///
/// The builder takes ownership of all heap-allocated values it creates
/// and will release them when `deinit` is called.
///
/// The returned builder starts with no fields and a reset internal state.
pub fn init(allocator: Allocator) JsonBuilder {
    return .{ .allocator = allocator };
}

/// Frees all resources owned by the JSON builder.
///
/// All heap-allocated string values stored in fields are released.
/// After freeing field values, the internal field list is deinitialized
/// and the line-append counter is reset.
///
/// This function must be called exactly once for every initialized builder
/// to avoid memory leaks.
pub fn deinit(this: *JsonBuilder) void {
    this.fields.deinit(this.allocator);
    this.counter = 0;
}

/// Clears all fields and resets the builder state for reuse.
///
/// This frees all heap-allocated string values but retains the
/// underlying field list capacity, making it efficient for reuse
/// in scenarios where the builder is used repeatedly.
///
/// After calling `clear()`, the builder can be used again as if
/// freshly initialized, but without reallocating the backing array.
pub fn clear(this: *JsonBuilder) void {
    this.fields.clearRetainingCapacity();
    this.counter = 0;
}

/// Sets a JSON field with a statically supported value type.
///
/// Supported value types:
/// - `[]const u8`, `[*:0]const u8` → JSON string
/// - Integer types (`u8/i8` … `u64/i64`) → JSON number
/// - `bool` → JSON boolean
///
/// Unsupported types cause a compile-time error.
///
/// This function does not perform key deduplication; setting the same key
/// multiple times will result in multiple entries in the output.
pub fn set(this: *JsonBuilder, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    const v = switch (T) {
        []const u8 => Value{ .string = value },
        []u8 => Value{ .string = value },
        *const [0:0]u8 => Value{ .string = value[0..] },
        bool => Value{ .boolean = value },
        u8, i8, u16, i16, u32, i32, u64, i64 => Value{ .number = @intCast(value) },
        else => @compileError("Unsupported JSON value type"),
    };

    try this.fields.append(this.allocator, .{
        .key = key,
        .value = v,
    });
}

/// Sets a JSON string field using a formatted string.
///
/// The formatted value is allocated and stored as a string field
/// associated with the given `key`.
///
/// This function does not check for existing keys; if the same key
/// is set multiple times, all entries will be written to the output.
/// Use this intentionally or ensure uniqueness at the call site.
pub fn setFmt(this: *JsonBuilder, key: []const u8, comptime value: []const u8, args: anytype) !void {
    const str = try fmt.allocPrint(this.allocator, value, args);
    try this.fields.append(this.allocator, .{
        .key = key,
        .value = .{ .string = str },
    });
}

/// Checks whether a field with the given key exists.
///
/// Returns `true` if any field in the builder has a matching key,
/// `false` otherwise.
///
/// This is useful for conditionally setting or appending values
/// without duplicating keys unintentionally.
pub fn has(this: *JsonBuilder, key: []const u8) bool {
    for (this.fields.items) |f| {
        if (mem.eql(u8, f.key, key)) return true;
    }

    return false;
}

/// Appends a formatted string to an existing JSON string field.
///
/// If a field with the given `key` already exists and its value is a string,
/// the formatted output is concatenated to the existing value.
///
/// If the key does not exist, a new string field is created.
///
/// Panics if the key exists but the associated value is not a string,
/// as appending is only valid for string fields.
pub fn appendFmt(this: *JsonBuilder, key: []const u8, comptime value: []const u8, args: anytype) !void {
    const part = try fmt.allocPrint(this.allocator, value, args);

    for (this.fields.items) |*f| {
        if (mem.eql(u8, f.key, key)) {
            switch (f.value) {
                .string => |old| {
                    const combined = try mem.concat(this.allocator, u8, &.{ old, part });
                    f.value = .{ .string = combined };
                    return;
                },
                else => @panic("appendFmt: key exists but value is not string"),
            }
        }
    }

    try this.fields.append(this.allocator, .{
        .key = key,
        .value = .{ .string = part },
    });
}

/// Appends a formatted string to a string field, inserting a newline if needed.
///
/// On the first append, the formatted value is added as-is.
/// On subsequent appends, a leading newline (`\n`) is automatically inserted
/// before the formatted value.
///
/// This is useful for building multi-line JSON string fields such as
/// Waybar tooltips, without having to manually track newline placement.
///
/// The internal `counter` is incremented after each call.
pub inline fn appendFmtNL(this: *JsonBuilder, key: []const u8, comptime value: []const u8, args: anytype) !void {
    if (!this.has(key)) try this.set(key, "");

    if (this.counter > 0) {
        try this.appendFmt(key, "\n" ++ value, args);
    } else {
        try this.appendFmt(key, value, args);
    }

    this.counter += 1;
}

/// Writes the JSON object to the given writer.
///
/// All stored fields are written as a single JSON object in insertion order.
/// Keys are written as JSON strings, and values are serialized via `writeValue`.
///
/// The output is compact (no extra whitespace) and ends with a newline,
/// making it suitable for streaming output (e.g. Waybar modules).
pub fn write(this: *JsonBuilder, writer: *Io.Writer) !void {
    try writer.writeAll("{");

    for (this.fields.items, 0..) |field, i| {
        if (i != 0) try writer.writeAll(",");

        try writer.print("\"{s}\":", .{field.key});
        try writeValue(writer, field.value);
    }

    try writer.writeAll("}");
    try writer.writeByte('\n');
}

/// Writes a JSON value to the given writer.
///
/// Strings are automatically quoted and escaped according to JSON rules.
/// Numbers and booleans are written in their JSON literal form.
///
/// This function does not write any surrounding whitespace.
pub inline fn writeValue(writer: *Io.Writer, value: Value) !void {
    switch (value) {
        .string => |s| {
            try writer.writeByte('"');
            try writeEscaped(writer, s);
            try writer.writeByte('"');
        },
        .number => |n| try writer.print("{d}", .{n}),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
    }
}

/// Writes a string with JSON-escaped characters to the given writer.
///
/// The following characters are escaped:
/// - `"`
/// - `\\`
/// - Newline (`\n`)
/// - Carriage return (`\r`)
/// - Tab (`\t`)
///
/// This function does **not** add surrounding quotes.
/// It is intended to be used internally by `writeValue`.
pub inline fn writeEscaped(writer: *Io.Writer, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
