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

const std = @import("std");
const uProcess = @import("utils").Process;
const findExecutable = uProcess.findExecutable;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const linux = std.os.linux;
const mem = std.mem;
const meta = std.meta;
const process = std.process;
const Child = process.Child;
const Environ = process.Environ;
const Map = Environ.Map;

pub const MAX_PKG_NAME = 255;
pub const MAX_VERSION_LENGTH = 50;

const DEFAULT_PACMAN_DB = "/var/lib/pacman/";
const WHITESPACE = &ascii.whitespace;

pub const UpdatesError = error{
    CannotFetchUpdates,
    NoSupportedManager,
};

pub const Managers = enum {
    apt,
    pacman,
    dnf,
    zypper,
    xbps,

    pub fn name(this: @This()) []const u8 {
        return @tagName(this);
    }
};

pub const UpdateInfo = struct {
    pkg_name: [MAX_PKG_NAME]u8,
    new_version: [MAX_VERSION_LENGTH + 1]u8,
};

/// Detects and returns the first available package manager.
pub fn getManager(io: Io, environ_map: *Map, allocator: Allocator) !Managers {
    inline for (meta.tags(Managers)) |manager| {
        if (try findExecutable(io, environ_map, allocator, manager.name())) |path| {
            allocator.free(path);
            return manager;
        }
    }
    return UpdatesError.NoSupportedManager;
}

/// Checks for updates and returns parsed update info, or null if none available.
pub fn checkUpdates(io: Io, environ_map: *Map, allocator: Allocator, manager: Managers) !?[]UpdateInfo {
    const output = try fetchUpdates(io, environ_map, allocator, manager);
    defer allocator.free(output);

    if (output.len == 0) return null;
    return try parseUpdates(allocator, manager, output);
}

/// Parses raw command output into structured update information.
pub fn parseUpdates(allocator: Allocator, manager: Managers, output: []const u8) ![]UpdateInfo {
    var updates: ArrayList(UpdateInfo) = .empty;
    errdefer updates.deinit(allocator);

    var lines = mem.splitScalar(u8, output, '\n');
    var skip_count: usize = if (manager == .zypper) 2 else 0;

    while (lines.next()) |line| {
        if (skip_count > 0) {
            skip_count -= 1;
            continue;
        }

        if (line.len == 0) continue;
        if (manager == .dnf and ascii.startsWithIgnoreCase(line, "Obsoleting packages")) break;

        var tmp_info: UpdateInfo = undefined;
        if (parseLine(manager, line, &tmp_info)) try updates.append(allocator, tmp_info);
    }

    return updates.toOwnedSlice(allocator);
}

fn fetchUpdates(io: Io, environ_map: *Map, allocator: Allocator, manager: Managers) ![]u8 {
    var pacman_db: ?[]u8 = null;
    defer if (pacman_db) |db| allocator.free(db);
    if (manager == .pacman) pacman_db = try setupPacmanDatabase(io, allocator, environ_map);

    const argv: []const []const u8 = switch (manager) {
        .apt => &.{ "apt", "list", "--upgradable" },
        .dnf => &.{ "dnf", "check-upgrade", "--refresh", "-yq" },
        .pacman => &.{ "pacman", "-Qu", "--dbpath", pacman_db.? },
        .zypper => &.{ "zypper", "--non-interactive", "lu" },
        .xbps => &.{ "xbps-install", "--dry-run", "--sync", "--update" },
    };

    var child = try process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .pipe });

    const stdout = try uProcess.readAll(io, allocator, child.stdout.?);
    errdefer allocator.free(stdout);

    const term = try child.wait(io);
    if (term != .exited) return &.{};

    return filterOutput(allocator, manager, stdout);
}

fn filterOutput(allocator: Allocator, manager: Managers, raw: []u8) ![]u8 {
    var result: ArrayList(u8) = .empty;
    var iter = mem.splitScalar(u8, raw, '\n');

    while (iter.next()) |line| {
        if (line.len == 0) continue;
        if (manager == .dnf and ascii.startsWithIgnoreCase(line, "Obsoleting packages")) break;

        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
    }

    return result.toOwnedSlice(allocator);
}

fn setupPacmanDatabase(io: Io, allocator: Allocator, environ_map: *Map) ![]u8 {
    const db_path = try getCheckupPath(allocator, environ_map);
    const pacman_db = try getPacmanDatabasePath(allocator, io);
    defer allocator.free(pacman_db);

    try createDirectory(io, db_path);
    try deleteLockFile(io, allocator, db_path);
    try createLocalSymlink(io, allocator, db_path, pacman_db);

    const status = try uProcess.runCommand(io, &.{ "fakeroot", "pacman", "-Sy", "--disable-sandbox", "--dbpath", db_path, "--logfile", "/dev/null" });

    if (status != 0) return UpdatesError.CannotFetchUpdates;
    return db_path;
}

fn getCheckupPath(allocator: Allocator, environ_map: *Map) ![]u8 {
    if (environ_map.get("CHECKUPDATES_DB")) |path| {
        return try allocator.dupe(u8, path);
    }

    const uid = linux.geteuid();
    return try fmt.allocPrint(allocator, "/run/user/{d}/zwc-updates-check", .{uid});
}

fn getPacmanDatabasePath(allocator: Allocator, io: Io) ![]const u8 {
    var child = process.spawn(io, .{
        .argv = &.{ "pacman-conf", "DBPath" },
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return try allocator.dupe(u8, DEFAULT_PACMAN_DB);

    const stdout = uProcess.readAll(io, allocator, child.stdout.?) catch {
        _ = child.wait(io) catch {};
        return try allocator.dupe(u8, DEFAULT_PACMAN_DB);
    };
    defer allocator.free(stdout);
    _ = child.wait(io) catch {};

    const trimmed = mem.trim(u8, stdout, WHITESPACE);
    return try allocator.dupe(u8, if (trimmed.len == 0) DEFAULT_PACMAN_DB else trimmed);
}

inline fn createDirectory(io: Io, path: []const u8) !void {
    Dir.createDirAbsolute(io, path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

inline fn deleteLockFile(io: Io, allocator: Allocator, db_path: []const u8) !void {
    const lock_path = try fmt.allocPrint(allocator, "{s}/db.lck", .{db_path});
    defer allocator.free(lock_path);
    Dir.deleteFileAbsolute(io, lock_path) catch {};
}

inline fn createLocalSymlink(io: Io, allocator: Allocator, db_path: []const u8, pacman_db: []const u8) !void {
    const local_path = try fmt.allocPrint(allocator, "{s}/local", .{db_path});
    defer allocator.free(local_path);

    const pacman_local = try fmt.allocPrint(allocator, "{s}local", .{pacman_db});
    defer allocator.free(pacman_local);

    Dir.symLinkAbsolute(io, pacman_local, local_path, .{}) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Parses a single line of package manager output into an UpdateInfo struct.
inline fn parseLine(manager: Managers, line: []const u8, info: *UpdateInfo) bool {
    const trimmed = mem.trim(u8, line, WHITESPACE);
    if (trimmed.len == 0) return false;

    var pkg_name: []const u8 = undefined;
    var new_version: []const u8 = undefined;

    switch (manager) {
        .apt => {
            const slash_idx = mem.findScalar(u8, trimmed, '/') orelse return false;
            pkg_name = trimmed[0..slash_idx];

            var parts_iter = mem.splitScalar(u8, trimmed, ' ');
            _ = parts_iter.next() orelse return false;
            new_version = parts_iter.next() orelse return false;
        },

        .dnf => {
            var parts = mem.tokenizeAny(u8, trimmed, " \t");
            const pkg_name_full = parts.next() orelse return false;
            new_version = parts.next() orelse return false;

            if (pkg_name_full.len == 0 or new_version.len == 0) return false;

            const dot_idx = mem.findScalarLast(u8, pkg_name_full, '.') orelse pkg_name_full.len;
            pkg_name = pkg_name_full[0..dot_idx];
        },

        .pacman => {
            const arrow_idx = mem.find(u8, trimmed, "->") orelse return false;
            const left_part = mem.trim(u8, trimmed[0..arrow_idx], WHITESPACE);
            new_version = mem.trim(u8, trimmed[arrow_idx + 2 ..], WHITESPACE);
            if (new_version.len == 0) return false;

            const last_space = mem.findScalar(u8, left_part, ' ') orelse return false;
            pkg_name = left_part[0..last_space];
        },

        .zypper => {
            if (trimmed[0] == '-' or ascii.startsWithIgnoreCase(trimmed, "S |")) return false;

            var parts_iter = mem.splitScalar(u8, trimmed, '|');
            _ = parts_iter.next();
            _ = parts_iter.next();
            const name_raw = parts_iter.next() orelse return false;
            _ = parts_iter.next() orelse return false;
            const available_raw = parts_iter.next() orelse return false;

            pkg_name = mem.trim(u8, name_raw, WHITESPACE);
            new_version = mem.trim(u8, available_raw, WHITESPACE);
        },

        .xbps => {
            var it = mem.tokenizeAny(u8, trimmed, " \t");
            const first = it.next() orelse return false;
            const second = it.next() orelse return false;

            if (!mem.eql(u8, second, "update")) return false;

            const hyphen_idx = mem.findScalarLast(u8, first, '-') orelse return false;
            const raw_name = first[0..hyphen_idx];
            const raw_version = first[hyphen_idx + 1 ..];

            pkg_name = mem.trim(u8, raw_name, WHITESPACE);
            const old_version = mem.trim(u8, raw_version, WHITESPACE);

            if (it.next()) |candidate| {
                new_version = if (ascii.isDigit(candidate[0])) candidate else old_version;
            } else {
                new_version = old_version;
            }
        },
    }

    if (pkg_name.len == 0 or new_version.len == 0) return false;
    if (pkg_name.len >= info.pkg_name.len or new_version.len >= info.new_version.len) return false;

    info.pkg_name[pkg_name.len] = 0;
    @memcpy(info.pkg_name[0..pkg_name.len], pkg_name);
    info.new_version[new_version.len] = 0;
    @memcpy(info.new_version[0..new_version.len], new_version);
    return true;
}

const testing = std.testing;

test "parseUpdates apt" {
    const output =
        \\Listing... Done
        \\libacl1/testing 2.3.2-2+b2 amd64 [upgradable from: 2.3.2-2+b1]
        \\libattr1/testing 1:2.5.2-3+b1 amd64 [upgradable from: 1:2.5.2-3]
        \\libbsd0/testing 0.12.2-2+b1 amd64 [upgradable from: 0.12.2-2]
        \\libbz2-1.0/testing 1.0.8-6+b1 amd64 [upgradable from: 1.0.8-6]
        \\libgmp10/testing 2:6.3.0+dfsg-5+b1 amd64 [upgradable from: 2:6.3.0+dfsg-5]
        \\liblzma5/testing 5.8.2-2 amd64 [upgradable from: 5.8.2-1]
        \\libmd0/testing 1.1.0-2+b2 amd64 [upgradable from: 1.1.0-2+b1]
        \\libpam-modules-bin/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpam-modules/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpam0g/testing 1.7.0-5+b1 amd64 [upgradable from: 1.7.0-5]
        \\libpcre2-8-0/testing 10.46-1+b1 amd64 [upgradable from: 10.46-1]
        \\libssl3t64/testing 3.5.4-1+b1 amd64 [upgradable from: 3.5.4-1]
        \\libxxhash0/testing 0.8.3-2+b1 amd64 [upgradable from: 0.8.3-2]
        \\libzstd1/testing 1.5.7+dfsg-3+b1 amd64 [upgradable from: 1.5.7+dfsg-3]
        \\openssl-provider-legacy/testing 3.5.4-1+b1 amd64 [upgradable from: 3.5.4-1]
        \\
    ;

    const updates = try parseUpdates(testing.allocator, .apt, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 15), updates.len);
    try testing.expectEqualStrings("libacl1", mem.sliceTo(&updates[0].pkg_name, 0));
    try testing.expectEqualStrings("2.3.2-2+b2", mem.sliceTo(&updates[0].new_version, 0));
    try testing.expectEqualStrings("libssl3t64", mem.sliceTo(&updates[11].pkg_name, 0));
    try testing.expectEqualStrings("3.5.4-1+b1", mem.sliceTo(&updates[11].new_version, 0));
}

test "parseUpdates dnf" {
    const output =
        \\coreutils.x86_64                   9.7-7.fc43        updates
        \\coreutils-common.x86_64            9.7-7.fc43        updates
        \\curl.x86_64                        8.15.0-4.fc43     updates
        \\glib2.x86_64                       2.86.3-1.fc43     updates
        \\glibc.x86_64                       2.42-5.fc43       updates
        \\glibc-common.x86_64                2.42-5.fc43       updates
        \\glibc-minimal-langpack.x86_64      2.42-5.fc43       updates
        \\gnupg2.x86_64                      2.4.9-1.fc43      updates
        \\gnupg2-dirmngr.x86_64              2.4.9-1.fc43      updates
        \\gnupg2-gpg-agent.x86_64            2.4.9-1.fc43      updates
        \\gnupg2-gpgconf.x86_64              2.4.9-1.fc43      updates
        \\Obsoleting Packages
        \\
    ;

    const updates = try parseUpdates(testing.allocator, .dnf, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 11), updates.len);
    try testing.expectEqualStrings("coreutils", mem.sliceTo(&updates[0].pkg_name, 0));
    try testing.expectEqualStrings("9.7-7.fc43", mem.sliceTo(&updates[0].new_version, 0));
}

test "parseUpdates pacman" {
    const output =
        \\alsa-card-profiles 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\glibc 2.42+r47+ga1d3294a5bed-2 -> 2.42+r50+g453e6b8dbab-2
        \\lib32-glibc 2.42+r47+ga1d3294a5bed-2 -> 2.42+r50+g453e6b8dbab-2
        \\lib32-libltdl 2.6.0-1 -> 2.6.0-2
        \\lib32-libpipewire 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-opencl-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-pipewire 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-pipewire-jack 1:1.4.9-1 -> 1:1.4.10-1
        \\lib32-vulkan-mesa-implicit-layers 1:25.3.3-5 -> 1:25.3.3-6
        \\lib32-vulkan-radeon 1:25.3.3-5 -> 1:25.3.3-6
        \\libpipewire 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\libpng-apng 1.6.50-1 -> 1.6.54-1
        \\libtool 2.6.0-1 -> 2.6.0-2
        \\linux-cachyos 6.18.5-2 -> 6.18.6-2
        \\linux-cachyos-headers 6.18.5-2 -> 6.18.6-2
        \\mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\meson 1.10.0-4 -> 1.10.1-1
        \\opencl-mesa 1:25.3.3-5 -> 1:25.3.3-6
        \\pacman 7.1.0.r7.gb9f7d4a-3 -> 7.1.0.r9.g54d9411-2
        \\pipewire 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-alsa 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-audio 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-jack 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\pipewire-pulse 1:1.4.9-2.1 -> 1:1.4.10-1.1
        \\rdma-core 60.0-3.1 -> 61.0-1.1
        \\vulkan-mesa-implicit-layers 1:25.3.3-5 -> 1:25.3.3-6
        \\vulkan-radeon 1:25.3.3-5 -> 1:25.3.3-6
    ;

    const updates = try parseUpdates(testing.allocator, .pacman, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 28), updates.len);
    try testing.expectEqualStrings("mesa", mem.sliceTo(&updates[16].pkg_name, 0));
    try testing.expectEqualStrings("1:25.3.3-6", mem.sliceTo(&updates[16].new_version, 0));
}

test "parseUpdates zypper" {
    const output =
        \\Loading repository data...
        \\Reading installed packages...
        \\S  | Repository                       | Name                              | Current Version                         | Available Version                       | Arch
        \\---+----------------------------------+-----------------------------------+-----------------------------------------+-----------------------------------------+-------
        \\v  | Asus Linux (OpenSUSE Tumbleweed) | asusctl                           | 6.3.0-1.suse.tw                         | 6.3.1-1.suse.tw                         | x86_64
        \\v  | Asus Linux (OpenSUSE Tumbleweed) | asusctl-rog-gui                   | 6.3.0-1.suse.tw                         | 6.3.1-1.suse.tw                         | x86_64
        \\v  | Brave Browser                    | brave-browser                     | 1.85.120-1                              | 1.86.139-1                              | x86_64
        \\v  | Visual Studio Code               | code                              | 1.108.0-1767882006.el8                  | 1.108.1-1768404278.el8                  | x86_64
        \\v  | Packman Essentials               | ffmpeg-4                          | 4.4.6-1699.10.0.5.pm.1                  | 4.4.6-1699.10.0.5.pm.2                  | x86_64
        \\v  | Packman Essentials               | gdk-pixbuf-loader-libheif         | 1.21.1-1699.4.pm.5                      | 1.21.2-1699.4.pm.1                      | x86_64
        \\v  | update-slowroll                  | kernel-default                    | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | x86_64
        \\v  | update-slowroll                  | kernel-default-devel              | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | x86_64
        \\v  | update-slowroll                  | kernel-devel                      | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | noarch
        \\v  | update-slowroll                  | kernel-firmware-platform          | 20251228-1.1                            | 20251228-2.0.2.1.sr20260101             | noarch
        \\v  | update-slowroll                  | kernel-macros                     | 6.18.3-1.0.6.1.sr20251204               | 6.18.5-1.0.2.1.sr20260101               | noarch
    ;

    const updates = try parseUpdates(testing.allocator, .zypper, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 12), updates.len);
    try testing.expectEqualStrings("code", mem.sliceTo(&updates[4].pkg_name, 0));
    try testing.expectEqualStrings("1.108.1-1768404278.el8", mem.sliceTo(&updates[4].new_version, 0));
}

test "parseUpdates xbps" {
    const output =
        \\acl-2.3.2_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 38896 16778
        \\attr-2.5.2_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 27289 9062
        \\base-files-0.146_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 262416 62583
        \\bzip2-1.0.8_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 149991 61053
        \\ca-certificates-20250419+3.118.1_1 update x86_64-musl https://repo-default.voidlinux.org/current/musl 284296 170936
        \\coreutils-9.4_3 update x86_64-musl https://repo-default.voidlinux.org/current/musl 21814162 3504523
        \\dash-0.5.12_2 update x86_64-musl https://repo-default.voidlinux.org/current/musl 194963 87212
    ;

    const updates = try parseUpdates(testing.allocator, .xbps, output);
    defer testing.allocator.free(updates);

    try testing.expectEqual(@as(usize, 7), updates.len);
    try testing.expectEqualStrings("acl", mem.sliceTo(&updates[0].pkg_name, 0));
    try testing.expectEqualStrings("2.3.2_1", mem.sliceTo(&updates[0].new_version, 0));
    try testing.expectEqualStrings("dash", mem.sliceTo(&updates[6].pkg_name, 0));
    try testing.expectEqualStrings("0.5.12_2", mem.sliceTo(&updates[6].new_version, 0));
}
