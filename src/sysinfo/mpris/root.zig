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

pub const MprisError = @import("MprisError.zig").MprisError;
pub const PlaybackStatus = @import("PlaybackStatus.zig").PlaybackStatus;
pub const LoopStatus = @import("LoopStatus.zig").LoopStatus;
pub const Metadata = @import("Metadata.zig");
pub const PlayerInfo = @import("PlayerInfo.zig");

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GStr = Value.GStr;
const GVariant = Value.GVariant;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const meta = std.meta;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

pub const MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
pub const MPRIS_PATH: [:0]const u8 = "/org/mpris/MediaPlayer2";
pub const PLAYER_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2.Player";
pub const ROOT_IFACE: [:0]const u8 = "org.mpris.MediaPlayer2";

pub fn listPlayers(allocator: Allocator, connection: *Connection) ![][]const u8 {
    var dbus_proxy = Proxy.init(
        connection,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    );

    var res = dbus_proxy.call("ListNames", .{}) catch return MprisError.ConnectionFailed;
    defer res.deinit();

    const names = res.expectAlloc([]GStr) catch return MprisError.InvalidResponse;
    defer {
        for (names) |n| allocator.free(n.s);
        allocator.free(names);
    }

    var players: ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (players.items) |p| allocator.free(p);
        players.deinit(allocator);
    }

    for (names) |name| {
        if (mem.startsWith(u8, name.s, MPRIS_PREFIX)) {
            try players.append(allocator, try allocator.dupe(u8, name.s));
        }
    }

    return players.toOwnedSlice(allocator);
}

pub fn getPlayerInfo(allocator: Allocator, connection: *Connection, bus_name: []const u8) !PlayerInfo {
    const player_name = if (bus_name.len > MPRIS_PREFIX.len)
        bus_name[MPRIS_PREFIX.len..]
    else
        bus_name;

    var info = PlayerInfo{
        .name = try allocator.dupe(u8, player_name),
    };
    errdefer info.deinit(allocator);

    // Sentinel-terminate the bus name for plume
    const bus_name_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{bus_name}, 0);
    defer allocator.free(bus_name_z);

    const root_proxy = Proxy.init(connection, bus_name_z, MPRIS_PATH, ROOT_IFACE);
    const player_proxy = Proxy.init(connection, bus_name_z, MPRIS_PATH, PLAYER_IFACE);

    // Identity
    if (root_proxy.getProperty(GVariant, "Identity")) |v| {
        var mv = v;
        defer mv.deinit(allocator);
        if (v == .string) info.identity = try allocator.dupe(u8, v.string.s);
    } else |_| {}

    // PlaybackStatus
    if (player_proxy.getProperty(GVariant, "PlaybackStatus")) |v| {
        var mv = v;
        defer mv.deinit(allocator);
        if (v == .string) {
            if (mem.eql(u8, v.string.s, "Playing")) info.status = .playing else if (mem.eql(u8, v.string.s, "Paused")) info.status = .paused else if (mem.eql(u8, v.string.s, "Stopped")) info.status = .stopped;
        }
    } else |_| {}

    // LoopStatus
    if (player_proxy.getProperty(GVariant, "LoopStatus")) |v| {
        var mv = v;
        defer mv.deinit(allocator);
        if (v == .string) {
            if (mem.eql(u8, v.string.s, "None")) info.loop_status = .none else if (mem.eql(u8, v.string.s, "Track")) info.loop_status = .track else if (mem.eql(u8, v.string.s, "Playlist")) info.loop_status = .playlist;
        }
    } else |_| {}

    // Boolean caps
    inline for (.{
        .{ "Shuffle", "shuffle" },
        .{ "CanControl", "can_control" },
        .{ "CanGoNext", "can_go_next" },
        .{ "CanGoPrevious", "can_go_previous" },
        .{ "CanPlay", "can_play" },
        .{ "CanPause", "can_pause" },
        .{ "CanSeek", "can_seek" },
    }) |pair| {
        if (player_proxy.getProperty(GVariant, pair[0])) |v| {
            var mv = v;
            defer mv.deinit(allocator);
            if (v == .boolean) @field(info, pair[1]) = v.boolean;
        } else |_| {}
    }

    // Volume
    if (player_proxy.getProperty(GVariant, "Volume")) |v| {
        var mv = v;
        defer mv.deinit(allocator);
        if (v == .double) info.volume = v.double;
    } else |_| {}

    // Position
    if (player_proxy.getProperty(GVariant, "Position")) |v| {
        var mv = v;
        defer mv.deinit(allocator);
        if (v == .int64) info.position_us = v.int64;
    } else |_| {}

    // Metadata
    info.metadata = getMetadataProperty(allocator, player_proxy);

    return info;
}

pub fn getActivePlayer(allocator: Allocator, connection: *Connection) !PlayerInfo {
    const players = try listPlayers(allocator, connection);
    defer {
        for (players) |p| allocator.free(p);
        allocator.free(players);
    }

    if (players.len == 0) return MprisError.NoPlayers;

    return getPlayerInfo(allocator, connection, players[0]);
}

fn getMetadataProperty(allocator: Allocator, player_proxy: Proxy) Metadata {
    var metadata: Metadata = .{};

    const v = player_proxy.getProperty(GVariant, "Metadata") catch return metadata;
    var mv = v;
    defer mv.deinit(allocator);

    // Metadata is a{sv}
    const dict = if (v == .variant) v.variant.* else v;
    if (dict != .dict) return metadata;

    var it = dict.dict.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const inner = if (val == .variant) val.variant.* else val;

        if (mem.eql(u8, key, "xesam:title")) {
            if (inner == .string) metadata.title = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "xesam:artist")) {
            if (inner == .array and inner.array.len > 0) {
                const first = inner.array[0];
                const s = if (first == .variant) first.variant.* else first;
                if (s == .string) metadata.artist = allocator.dupe(u8, s.string.s) catch null;
            } else if (inner == .string) {
                metadata.artist = allocator.dupe(u8, inner.string.s) catch null;
            }
        } else if (mem.eql(u8, key, "xesam:album")) {
            if (inner == .string) metadata.album = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "mpris:artUrl")) {
            if (inner == .string) metadata.art_url = allocator.dupe(u8, inner.string.s) catch null;
        } else if (mem.eql(u8, key, "mpris:trackid")) {
            if (inner == .string or inner == .object_path) {
                const s = if (inner == .object_path) inner.object_path.s else inner.string.s;
                metadata.track_id = allocator.dupe(u8, s) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:length")) {
            if (inner == .int64) metadata.length_us = inner.int64;
        }
    }

    return metadata;
}

// Tests

const testing = std.testing;

test "PlaybackStatus.toString" {
    try testing.expectEqualStrings("playing", PlaybackStatus.playing.toString());
    try testing.expectEqualStrings("paused", PlaybackStatus.paused.toString());
    try testing.expectEqualStrings("stopped", PlaybackStatus.stopped.toString());
}

test "LoopStatus.toString" {
    try testing.expectEqualStrings("none", LoopStatus.none.toString());
    try testing.expectEqualStrings("track", LoopStatus.track.toString());
    try testing.expectEqualStrings("playlist", LoopStatus.playlist.toString());
}

test "Metadata.deinit" {
    const allocator = testing.allocator;

    var metadata = Metadata{
        .title = try allocator.dupe(u8, "Test Title"),
        .artist = try allocator.dupe(u8, "Test Artist"),
        .album = try allocator.dupe(u8, "Test Album"),
    };

    metadata.deinit(allocator);

    try testing.expectEqual(@as(?[]const u8, null), metadata.title);
    try testing.expectEqual(@as(?[]const u8, null), metadata.artist);
    try testing.expectEqual(@as(?[]const u8, null), metadata.album);
}

test "PlayerInfo.deinit" {
    const allocator = testing.allocator;

    var info = PlayerInfo{
        .name = try allocator.dupe(u8, "testplayer"),
        .identity = try allocator.dupe(u8, "Test Player"),
        .status = .playing,
        .metadata = .{
            .title = try allocator.dupe(u8, "Song"),
        },
    };

    info.deinit(allocator);
}
