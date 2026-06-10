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

/// Provides helper utilities for rendering custom text and tooltip output.
const Output = @This();

const std = @import("std");
const Replacer = @import("Replacer.zig");
const JsonBuilder = @import("Json.zig");
const mem = std.mem;
const Allocator = mem.Allocator;

/// Renders text output using either a custom template or default value.
///
/// If `template` is provided, the replacer substitutes all registered
/// placeholders and sets the result as the "text" field.
/// Otherwise, falls back to `default_text`.
///
/// The caller must ensure the replacer has been populated with all
/// necessary placeholder values before calling this function.
pub fn renderText(json_builder: *JsonBuilder, replacer: *Replacer, template: ?[]const u8, default_text: []const u8) !void {
    if (template) |tmpl| {
        const rendered = try replacer.render(tmpl);
        try json_builder.set("text", rendered);
    } else {
        try json_builder.set("text", default_text);
    }
}

/// Renders tooltip output using either a custom template or default value.
///
/// If `template` is provided, the replacer substitutes all registered
/// placeholders and sets the result as the "tooltip" field.
/// Otherwise, falls back to `default_tooltip`.
///
/// The caller must ensure the replacer has been populated with all
/// necessary placeholder values before calling this function.
pub fn renderTooltip(json_builder: *JsonBuilder, replacer: *Replacer, template: ?[]const u8, default_tooltip: []const u8) !void {
    if (template) |tmpl| {
        const rendered = try replacer.render(tmpl);
        try json_builder.set("tooltip", rendered);
    } else {
        try json_builder.set("tooltip", default_tooltip);
    }
}

/// Adds common placeholders that are available across all modules.
///
/// This includes:
/// - `{newline}` `{nl}` → literal newline character
/// - `{tab}` → literal tab character
/// - `{dot}` → literal dot character
/// - `{pipe}` → literal pipe character
pub inline fn addCommonPlaceholders(replacer: *Replacer) !void {
    try replacer.add("{newline}", "\n");
    try replacer.add("{nl}", "\n");
    try replacer.add("{tab}", "\t");
    try replacer.add("{dot}", "·");
    try replacer.add("{pipe}", "|");
}
