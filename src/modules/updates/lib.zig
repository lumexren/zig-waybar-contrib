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

/// Implements package update checking across multiple package managers
const Module = @This();

const std = @import("std");
const core = @import("core");
const ArrayList = std.ArrayList;
const Io = std.Io;
const Duration = Io.Duration;
const mem = std.mem;
const Allocator = mem.Allocator;
const ascii = std.ascii;
const posix = std.posix;
const os = std.os;
const linux = os.linux;
const process = std.process;
const Environ = process.Environ;
const Child = process.Child;
const fmt = std.fmt;

const json = core.json;

environ: Environ,
allocator: Allocator,
io: Io,
writer: *Io.Writer,
manager: Managers,
config: Config = .{},
pacman_db_path: ?[]u8 = "",

pub const BUFFER_SIZE = 4096;
pub const MAX_VERSION_LENGTH = 50;
pub const MAX_UPDATES = 75;

pub const Managers = enum {
    apt,
    pacman,
    dnf,
    zypper,

    pub fn name(this: @This()) []const u8 {
        return switch (this) {
            .apt => "apt",
            .pacman => "pacman",
            .dnf => "dnf",
            .zypper => "zypper",
        };
    }
};

pub const Config = struct {
    check_interval: i64 = 200,
    icon: []const u8 = "",
    err_icon: []const u8 = "",
    text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

pub const UpdatesError = error{
    CannotFetchUpdates,
};

pub const UpdateInfo = struct {
    pkg_name: [BUFFER_SIZE]u8,
    new_version: [MAX_VERSION_LENGTH + 1]u8,
};

pub fn init(environ: Environ, allocator: Allocator, io: Io, writer: *Io.Writer, manager: Managers, config: Config) Module {
    return .{ .environ = environ, .allocator = allocator, .io = io, .writer = writer, .manager = manager, .config = config };
}

fn parseLine(this: *Module, line: []const u8, info: *UpdateInfo) bool {
    const trimmed = mem.trim(u8, line, &ascii.whitespace);
    if (trimmed.len == 0) return false;

    var pkg_name: []const u8 = undefined;
    var new_version: []const u8 = undefined;

    switch (this.manager) {
        .apt => {
            const slash_idx = mem.find(u8, trimmed, "/") orelse return false;
            pkg_name = trimmed[0..slash_idx];

            var parts_iter = mem.splitAny(u8, trimmed, " ");
            _ = parts_iter.next() orelse return false;
            new_version = parts_iter.next() orelse return false;
        },

        .dnf => {
            var parts = mem.tokenizeAny(u8, trimmed, " \t");
            const pkg_name_full = parts.next() orelse return false;
            new_version = parts.next() orelse return false;

            if (pkg_name_full.len == 0 or new_version.len == 0) return false;

            var pkg_len = pkg_name_full.len;
            const dot_idx = mem.findLast(u8, pkg_name_full, ".") orelse pkg_len;
            if (dot_idx != pkg_len) pkg_len = dot_idx;
            pkg_name = pkg_name_full[0..pkg_len];
        },

        .pacman => {
            const arrow_idx = mem.find(u8, trimmed, "->") orelse return false;
            const left_part = mem.trim(u8, trimmed[0..arrow_idx], &ascii.whitespace);
            new_version = mem.trim(u8, trimmed[arrow_idx + 2 ..], &ascii.whitespace);
            if (new_version.len == 0) return false;

            const last_space = mem.find(u8, left_part, " ") orelse return false;
            pkg_name = left_part[0..last_space];
        },

        .zypper => {
            if (trimmed[0] == '-' or ascii.startsWithIgnoreCase(trimmed, "S |")) return false;

            var parts_iter = mem.splitAny(u8, trimmed, "|");

            _ = parts_iter.next();
            _ = parts_iter.next();
            const name_raw = parts_iter.next() orelse return false;
            _ = parts_iter.next() orelse return false;
            const available_raw = parts_iter.next() orelse return false;

            pkg_name = mem.trim(u8, name_raw, &ascii.whitespace);
            new_version = mem.trim(u8, available_raw, &ascii.whitespace);
        },
    }

    if (pkg_name.len == 0 or new_version.len == 0) return false;
    if (pkg_name.len >= info.pkg_name.len or new_version.len >= info.new_version.len) return false;

    @memset(&info.pkg_name, 0);
    @memset(&info.new_version, 0);

    @memcpy(info.pkg_name[0..pkg_name.len], pkg_name);
    @memcpy(info.new_version[0..new_version.len], new_version);

    return true;
}

fn getPacmanUpdates(this: *Module) !void {
    const tmp_base = this.environ.getPosix("CHECKUPDATES_DB") orelse blk: {
        const tmpdir = this.environ.getPosix("TMPDIR") orelse "/tmp";
        const uid = linux.geteuid();

        var buf: [linux.PATH_MAX]u8 = undefined;
        break :blk fmt.bufPrint(&buf, "{s}/checkup-db-{d}", .{ tmpdir, uid }) catch "/tmp/checkup-db-0";
    };

    var db_path_buf: [linux.PATH_MAX]u8 = undefined;
    @memcpy(db_path_buf[0..tmp_base.len], tmp_base);
    const db_path = db_path_buf[0..tmp_base.len];

    this.pacman_db_path = db_path;

    const pacman_db_path = blk: {
        var child: Child = process.spawn(this.io, .{
            .argv = &[_][]const u8{ "pacman-conf", "DBPath" },
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch break :blk "/var/lib/pacman/";

        var buffer: [linux.PATH_MAX]u8 = undefined;
        var slices: [1][]u8 = .{buffer[0..]};

        const n = child.stdout.?.readStreaming(this.io, slices[0..]) catch break :blk "/var/lib/pacman/";
        _ = child.wait(this.io) catch {};

        const trimmed = mem.trim(u8, buffer[0..n], &ascii.whitespace);
        if (trimmed.len == 0) break :blk "/var/lib/pacman/";
        break :blk trimmed;
    };

    Io.Dir.createDirAbsolute(this.io, db_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var lock_path_buf: [linux.PATH_MAX]u8 = undefined;
    const lock_path = try fmt.bufPrint(&lock_path_buf, "{s}/db.lck", .{db_path});
    Io.Dir.deleteFileAbsolute(this.io, lock_path) catch {};

    var local_path_buf: [linux.PATH_MAX]u8 = undefined;
    const local_path = try fmt.bufPrint(&local_path_buf, "{s}/local", .{db_path});

    var pacman_local_buf: [linux.PATH_MAX]u8 = undefined;
    const pacman_local = try fmt.bufPrint(&pacman_local_buf, "{s}local", .{pacman_db_path});

    Io.Dir.symLinkAbsolute(this.io, pacman_local, local_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const status = try core.process.runCommand(this.io, &[_][]const u8{ "fakeroot", "pacman", "-Sy", "--disable-sandbox", "--dbpath", db_path, "--logfile", "/dev/null" });
    if (status != 0) return UpdatesError.CannotFetchUpdates;
}

fn getUpdates(this: *Module) ![]u8 {
    if (this.manager == .pacman) try this.getPacmanUpdates();

    const command: []const []const u8 = switch (this.manager) {
        .apt => &[_][]const u8{ "apt", "list", "--upgradable" },
        .dnf => &[_][]const u8{ "dnf", "check-upgrade", "--refresh", "-yq" },
        .pacman => &[_][]const u8{ "pacman", "-Qu", "--dbpath", this.pacman_db_path.? },
        .zypper => &[_][]const u8{ "zypper", "--non-interactive", "lu" },
    };

    var child: Child = try process.spawn(this.io, .{
        .argv = command,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const stdout = try core.readAll(this.allocator, this.io, child.stdout.?);

    const term = try child.wait(this.io);
    if (term != .exited) return &[_]u8{};

    var lines = ArrayList(u8).empty;
    var iter = mem.splitAny(u8, stdout, "\n");
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (this.manager == .dnf and ascii.startsWithIgnoreCase(line, "Obsoleting packages")) break;

        try lines.appendSlice(this.allocator, line);
        try lines.append(this.allocator, '\n');
    }

    return lines.toOwnedSlice(this.allocator);
}

pub fn checkUpdates(this: *Module, json_builder: *json, error_buffer: anytype) !void {
    const result = this.getUpdates();

    if (result) |updates_output| {
        if (updates_output.len == 0) return;

        var updates = try this.allocator.alloc(UpdateInfo, MAX_UPDATES);
        var total_updates: usize = 0;
        var visible_count: usize = 0;
        var json_buffer: [BUFFER_SIZE * 2]u8 = undefined;
        var output_buffer: [BUFFER_SIZE * MAX_UPDATES]u8 = undefined;
        var updateWriter: Io.Writer = .fixed(&output_buffer);
        var skip_headers: usize = 2;

        var lines = mem.splitAny(u8, updates_output, "\n");

        while (lines.next()) |line| {
            if (this.manager == .zypper and skip_headers > 0) {
                skip_headers -= 1;
                continue;
            }

            if (line.len == 0) continue;

            var tmp_info: UpdateInfo = undefined;
            if (this.parseLine(line, &tmp_info)) {
                total_updates += 1;
                if (visible_count < MAX_UPDATES) {
                    updates[visible_count] = tmp_info;
                    visible_count += 1;
                }
            }
        }

        for (updates[0..visible_count]) |update| {
            try updateWriter.print("{s:<25} {s}\n", .{
                mem.sliceTo(&update.pkg_name, 0),
                mem.sliceTo(&update.new_version, 0),
            });
        }

        if (total_updates > MAX_UPDATES) {
            const extra = total_updates - MAX_UPDATES;
            try updateWriter.print("...and more {d} updates", .{extra});
        }

        const written = updateWriter.end;
        if (written > 0 and output_buffer[written - 1] == '\n') updateWriter.end -= 1;

        core.escapeJson(output_buffer[0..updateWriter.end], &json_buffer);

        const updates_list = mem.sliceTo(&json_buffer, 0);

        // Build default text and tooltip
        var default_text_buf: [256]u8 = undefined;
        const default_text = fmt.bufPrint(&default_text_buf, "{s} {d}", .{ this.config.icon, total_updates }) catch "";

        // Use custom templates if provided
        if (this.config.text != null or this.config.tooltip != null) {
            var replacer = core.Replacer.init(this.allocator);
            defer replacer.deinit();

            try core.output.addCommonPlaceholders(&replacer);
            try replacer.addKey("icon", this.config.icon);
            try replacer.addKey("err_icon", this.config.err_icon);
            try replacer.addKeyAny("total_updates", total_updates);
            try replacer.addKey("updates_list", updates_list);

            try core.output.renderText(json_builder, &replacer, this.config.text, default_text);
            try core.output.renderTooltip(json_builder, &replacer, this.config.tooltip, updates_list);
        } else {
            try json_builder.set("text", default_text);
            try json_builder.set("tooltip", updates_list);
        }
    } else |err| {
        const msg = fmt.bufPrint(error_buffer, "Error: {s}", .{@errorName(err)}) catch "Unknown";
        core.escapeJson(msg, error_buffer);

        var default_text_buf: [256]u8 = undefined;
        const default_text = fmt.bufPrint(&default_text_buf, "{s} err", .{this.config.err_icon}) catch "";
        const err_tooltip = mem.sliceTo(error_buffer, 0);

        // Use custom templates if provided (for error case)
        if (this.config.text != null or this.config.tooltip != null) {
            var replacer = core.Replacer.init(this.allocator);
            defer replacer.deinit();

            try core.output.addCommonPlaceholders(&replacer);
            try replacer.addKey("icon", this.config.icon);
            try replacer.addKey("err_icon", this.config.err_icon);
            try replacer.addKeyAny("total_updates", @as(usize, 0));
            try replacer.addKey("updates_list", err_tooltip);

            try core.output.renderText(json_builder, &replacer, this.config.text, default_text);
            try core.output.renderTooltip(json_builder, &replacer, this.config.tooltip, err_tooltip);
        } else {
            try json_builder.set("text", default_text);
            try json_builder.set("tooltip", err_tooltip);
        }
    }

    try json_builder.write(this.writer);
}
