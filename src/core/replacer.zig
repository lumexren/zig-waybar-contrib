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

/// Applies ordered byte-sequence replacements to a template.
///
/// `Replacer` stores a list of replacement rules and can render a template
/// by applying them sequentially. Replacements may either borrow slices
/// from the caller or own their memory, depending on how they are added.
///
/// The replacer writes output either by returning an owned buffer or
/// directly to a provided writer.
const Replacer = @This();

const std = @import("std");
const ArrayList = std.ArrayList;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

allocator: Allocator,
replacements: ArrayList(Replacement) = .empty,
strict: bool = false,

/// Represents a byte-sequence replacement rule.
///
/// `from` specifies the byte slice to be matched.
/// `to` specifies the byte slice that will replace each occurrence of `from`.
/// `owned` tracks whether this replacement owns its memory for proper cleanup.
const Replacement = struct {
    from: []const u8,
    to: []const u8,
    owned: bool,
};

/// Initializes a replacer with the given allocator.
///
/// The returned instance does not allocate until replacements are added
/// or rendering is performed.
pub fn init(allocator: Allocator) Replacer {
    return .{ .allocator = allocator };
}

/// Frees all owned replacement data and internal storage.
///
/// After calling this function, the replacer must not be used again
/// unless reinitialized.
pub fn deinit(this: *Replacer) void {
    defer this.replacements.deinit(this.allocator);
}

/// Removes all replacements while retaining allocated capacity.
///
/// Any owned replacement slices are freed.
pub fn clear(this: *Replacer) void {
    defer this.replacements.clearRetainingCapacity();
}

/// Returns the number of registered replacement rules.
pub fn count(this: *const Replacer) usize {
    return this.replacements.items.len;
}

/// Enables or disables strict replacement mode.
///
/// When strict mode is enabled, rendering fails if a replacement's
/// `from` slice does not appear at least once in the template.
pub fn setStrict(this: *Replacer, enabled: bool) void {
    this.strict = enabled;
}

/// Adds a replacement rule using borrowed slices.
///
/// The caller must ensure that `from` and `to` remain valid for the
/// lifetime of the replacer or until `clear`/`deinit` is called.
pub fn add(this: *Replacer, from: []const u8, to: []const u8) !void {
    try this.replacements.append(this.allocator, .{ .from = from, .to = to, .owned = false });
}

/// Adds a replacement rule by copying the provided slices.
///
/// The replacer takes ownership of the duplicated memory and will
/// free it during `clear` or `deinit`.
pub fn addOwned(this: *Replacer, from: []const u8, to: []const u8) !void {
    const from_owned = try this.allocator.dupe(u8, from);
    const to_owned = try this.allocator.dupe(u8, to);

    try this.replacements.append(this.allocator, .{ .from = from_owned, .to = to_owned, .owned = true });
}

/// Adds a replacement rule for a templated key.
///
/// The key is wrapped in `{}` to form the `from` pattern, e.g.
/// `{name}`, and replaced with `value`.
///
/// Both slices are owned by the replacer.
pub fn addKey(this: *Replacer, key: []const u8, value: []const u8) !void {
    const from = try fmt.allocPrint(this.allocator, "{{{s}}}", .{key});
    const to = try this.allocator.dupe(u8, value);

    try this.replacements.append(this.allocator, .{ .from = from, .to = to, .owned = true });
}

/// Adds a replacement rule for a templated key using an arbitrary value.
///
/// The key is wrapped in `{}` to form the placeholder pattern (e.g. `{count}`).
/// The provided value may be of any type supported by `std.fmt`, including
/// integers, floats, booleans, enums, and strings.
///
/// The generated string is owned by the replacer and will be freed during
/// `clear` or `deinit`.
pub fn addKeyAny(this: *Replacer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    // Handle string types directly
    if (T == []const u8 or T == []u8) {
        return this.addKey(key, value);
    }

    // Format non-string types
    const str = try fmt.allocPrint(this.allocator, "{any}", .{value});

    try this.addKey(key, str);
}

/// Renders the template and returns an owned buffer.
///
/// Replacements are applied sequentially in insertion order.
/// The caller owns the returned slice and must free it with
/// the same allocator.
///
/// In strict mode, this function returns `error.PlaceholderNotFound`
/// if any replacement pattern is missing from the template.
pub fn render(this: *Replacer, template: []const u8) ![]u8 {
    var result = try this.allocator.dupe(u8, template);

    for (this.replacements.items) |r| {
        if (this.strict and mem.indexOf(u8, result, r.from) == null) return error.PlaceholderNotFound;

        const new_result = try mem.replaceOwned(u8, this.allocator, result, r.from, r.to);
        result = new_result;
    }

    return result;
}
