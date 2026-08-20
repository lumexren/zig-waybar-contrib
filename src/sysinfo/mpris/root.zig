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

pub const MprisError = @import("MprisError.zig").MprisError;
pub const PlaybackStatus = @import("PlaybackStatus.zig").PlaybackStatus;
pub const LoopStatus = @import("LoopStatus.zig").LoopStatus;
pub const Metadata = @import("Metadata.zig");
pub const PlayerInfo = @import("PlayerInfo.zig");

const dbus = @import("bindings").dbus;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const meta = std.meta;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
pub const MPRIS_PATH: [:0]const u8 = "/org/mpris/MediaPlayer2";

pub fn listPlayers(allocator: Allocator) ![][]const u8 {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SESSION, &err) orelse return MprisError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return MprisError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const msg = dbus.dbus_message_new_method_call(
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
        "ListNames",
    ) orelse return MprisError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, -1, &err) orelse return MprisError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return MprisError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var players: ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (players.items) |p| allocator.free(p);
        players.deinit(allocator);
    }

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return MprisError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_ARRAY) return MprisError.InvalidResponse;

    var sub_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &sub_iter);

    while (dbus.dbus_message_iter_get_arg_type(&sub_iter) == dbus.TYPE_STRING) {
        var name_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&sub_iter, @ptrCast(&name_ptr));

        const name_slice = mem.sliceTo(name_ptr, 0);
        if (mem.startsWith(u8, name_slice, MPRIS_PREFIX)) {
            const duped = try allocator.dupe(u8, name_slice);
            try players.append(allocator, duped);
        }

        _ = dbus.dbus_message_iter_next(&sub_iter);
    }

    return players.toOwnedSlice(allocator);
}

pub fn getPlayerInfo(allocator: Allocator, bus_name: []const u8) !PlayerInfo {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SESSION, &err) orelse return MprisError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return MprisError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const player_name = if (bus_name.len > MPRIS_PREFIX.len)
        bus_name[MPRIS_PREFIX.len..]
    else
        bus_name;

    var info = PlayerInfo{
        .name = try allocator.dupe(u8, player_name),
    };
    errdefer info.deinit(allocator);

    const bus_name_z = try allocator.dupe(u8, bus_name);
    defer allocator.free(bus_name_z);

    info.identity = getStringProperty(allocator, conn, bus_name_z, "org.mpris.MediaPlayer2", "Identity");

    if (getStringProperty(allocator, conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "PlaybackStatus")) |status_str| {
        defer allocator.free(status_str);
        if (mem.eql(u8, status_str, "Playing")) {
            info.status = .playing;
        } else if (mem.eql(u8, status_str, "Paused")) {
            info.status = .paused;
        } else if (mem.eql(u8, status_str, "Stopped")) {
            info.status = .stopped;
        } else if (meta.stringToEnum(PlaybackStatus, status_str)) |status| {
            info.status = status;
        }
    }

    if (getStringProperty(allocator, conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "LoopStatus")) |status_str| {
        defer allocator.free(status_str);
        if (mem.eql(u8, status_str, "None")) {
            info.loop_status = .none;
        } else if (mem.eql(u8, status_str, "Track")) {
            info.loop_status = .track;
        } else if (mem.eql(u8, status_str, "Playlist")) {
            info.loop_status = .playlist;
        } else if (meta.stringToEnum(LoopStatus, status_str)) |status| {
            info.loop_status = status;
        }
    }

    info.shuffle = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "Shuffle");
    info.can_control = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanControl");
    info.can_go_next = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanGoNext");
    info.can_go_previous = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanGoPrevious");
    info.can_play = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanPlay");
    info.can_pause = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanPause");
    info.can_seek = getBoolProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "CanSeek");

    info.volume = getDoubleProperty(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "Volume");
    info.position_us = getInt64Property(conn, bus_name_z, "org.mpris.MediaPlayer2.Player", "Position");

    info.metadata = getMetadataProperty(allocator, conn, bus_name_z);

    return info;
}

pub fn getActivePlayer(allocator: Allocator) !PlayerInfo {
    const players = try listPlayers(allocator);
    defer {
        for (players) |p| allocator.free(p);
        allocator.free(players);
    }

    if (players.len == 0) return MprisError.NoPlayers;

    return getPlayerInfo(allocator, players[0]);
}

fn getStringProperty(allocator: Allocator, conn: *dbus.Connection, dest: []const u8, iface: [*:0]const u8, prop: [*:0]const u8) ?[]const u8 {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    var dest_buf: [256]u8 = undefined;
    if (dest.len >= dest_buf.len) return null;
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;
    const dest_z = dest_buf[0..dest.len :0].ptr;

    const msg = dbus.dbus_message_new_method_call(dest_z, MPRIS_PATH.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return null;
    defer dbus.dbus_message_unref(msg);

    var args: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args);

    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&iface)) == 0) return null;
    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&prop)) == 0) return null;

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err) orelse return null;
    if (dbus.dbus_error_is_set(&err) != 0) return null;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return null;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_VARIANT) return null;

    var variant_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &variant_iter);

    if (dbus.dbus_message_iter_get_arg_type(&variant_iter) != dbus.TYPE_STRING) return null;

    var value_ptr: [*:0]const u8 = undefined;
    dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&value_ptr));

    return allocator.dupe(u8, mem.sliceTo(value_ptr, 0)) catch null;
}

fn getBoolProperty(conn: *dbus.Connection, dest: []const u8, iface: [*:0]const u8, prop: [*:0]const u8) bool {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    var dest_buf: [256]u8 = undefined;
    if (dest.len >= dest_buf.len) return false;
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;
    const dest_z = dest_buf[0..dest.len :0].ptr;

    const msg = dbus.dbus_message_new_method_call(dest_z, MPRIS_PATH.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return false;
    defer dbus.dbus_message_unref(msg);

    var args: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args);

    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&iface)) == 0) return false;
    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&prop)) == 0) return false;

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err) orelse return false;
    if (dbus.dbus_error_is_set(&err) != 0) return false;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return false;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_VARIANT) return false;

    var variant_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &variant_iter);

    if (dbus.dbus_message_iter_get_arg_type(&variant_iter) != dbus.TYPE_BOOLEAN) return false;

    var value: u32 = 0;
    dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&value));

    return value != 0;
}

fn getDoubleProperty(conn: *dbus.Connection, dest: []const u8, iface: [*:0]const u8, prop: [*:0]const u8) f64 {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    var dest_buf: [256]u8 = undefined;
    if (dest.len >= dest_buf.len) return 1.0;
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;
    const dest_z = dest_buf[0..dest.len :0].ptr;

    const msg = dbus.dbus_message_new_method_call(dest_z, MPRIS_PATH.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return 1.0;
    defer dbus.dbus_message_unref(msg);

    var args: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args);

    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&iface)) == 0) return 1.0;
    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&prop)) == 0) return 1.0;

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err) orelse return 1.0;
    if (dbus.dbus_error_is_set(&err) != 0) return 1.0;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return 1.0;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_VARIANT) return 1.0;

    var variant_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &variant_iter);

    if (dbus.dbus_message_iter_get_arg_type(&variant_iter) != dbus.TYPE_DOUBLE) return 1.0;

    var value: f64 = 1.0;
    dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&value));

    return value;
}

fn getInt64Property(conn: *dbus.Connection, dest: []const u8, iface: [*:0]const u8, prop: [*:0]const u8) i64 {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    var dest_buf: [256]u8 = undefined;
    if (dest.len >= dest_buf.len) return 0;
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;
    const dest_z = dest_buf[0..dest.len :0].ptr;

    const msg = dbus.dbus_message_new_method_call(dest_z, MPRIS_PATH.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return 0;
    defer dbus.dbus_message_unref(msg);

    var args: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args);

    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&iface)) == 0) return 0;
    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&prop)) == 0) return 0;

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err) orelse return 0;
    if (dbus.dbus_error_is_set(&err) != 0) return 0;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return 0;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_VARIANT) return 0;

    var variant_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &variant_iter);

    if (dbus.dbus_message_iter_get_arg_type(&variant_iter) != dbus.TYPE_INT64) return 0;

    var value: i64 = 0;
    dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&value));

    return value;
}

fn getMetadataProperty(allocator: Allocator, conn: *dbus.Connection, dest: []const u8) Metadata {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const iface: [*:0]const u8 = "org.mpris.MediaPlayer2.Player";
    const prop: [*:0]const u8 = "Metadata";

    var dest_buf: [256]u8 = undefined;
    if (dest.len >= dest_buf.len) return .{};
    @memcpy(dest_buf[0..dest.len], dest);
    dest_buf[dest.len] = 0;
    const dest_z = dest_buf[0..dest.len :0];

    const msg = dbus.dbus_message_new_method_call(dest_z, MPRIS_PATH.ptr, "org.freedesktop.DBus.Properties", "Get") orelse return .{};
    defer dbus.dbus_message_unref(msg);

    var args: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args);

    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&iface)) == 0) return .{};
    if (dbus.dbus_message_iter_append_basic(&args, dbus.TYPE_STRING, @ptrCast(&prop)) == 0) return .{};

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 1000, &err) orelse return .{};
    if (dbus.dbus_error_is_set(&err) != 0) return .{};
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return .{};

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_VARIANT) return .{};

    var variant_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &variant_iter);

    if (dbus.dbus_message_iter_get_arg_type(&variant_iter) != dbus.TYPE_ARRAY) return .{};

    var metadata: Metadata = .{};
    errdefer metadata.deinit(allocator);

    var dict_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&variant_iter, &dict_iter);

    while (dbus.dbus_message_iter_get_arg_type(&dict_iter) == dbus.TYPE_DICT_ENTRY) {
        var entry_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&dict_iter, &entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_STRING) {
            _ = dbus.dbus_message_iter_next(&dict_iter);
            continue;
        }

        var key_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&entry_iter, @ptrCast(&key_ptr));
        const key = mem.sliceTo(key_ptr, 0);

        _ = dbus.dbus_message_iter_next(&entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_VARIANT) {
            _ = dbus.dbus_message_iter_next(&dict_iter);
            continue;
        }

        var value_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&entry_iter, &value_iter);

        const value_type = dbus.dbus_message_iter_get_arg_type(&value_iter);

        if (mem.eql(u8, key, "xesam:title")) {
            if (value_type == dbus.TYPE_STRING) {
                var str_ptr: [*:0]const u8 = undefined;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&str_ptr));
                metadata.title = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
            }
        } else if (mem.eql(u8, key, "xesam:artist")) {
            if (value_type == dbus.TYPE_ARRAY) {
                var artist_iter: dbus.MessageIter = .{};
                dbus.dbus_message_iter_recurse(&value_iter, &artist_iter);
                if (dbus.dbus_message_iter_get_arg_type(&artist_iter) == dbus.TYPE_STRING) {
                    var str_ptr: [*:0]const u8 = undefined;
                    dbus.dbus_message_iter_get_basic(&artist_iter, @ptrCast(&str_ptr));
                    metadata.artist = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
                }
            } else if (value_type == dbus.TYPE_STRING) {
                var str_ptr: [*:0]const u8 = undefined;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&str_ptr));
                metadata.artist = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
            }
        } else if (mem.eql(u8, key, "xesam:album")) {
            if (value_type == dbus.TYPE_STRING) {
                var str_ptr: [*:0]const u8 = undefined;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&str_ptr));
                metadata.album = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:artUrl")) {
            if (value_type == dbus.TYPE_STRING) {
                var str_ptr: [*:0]const u8 = undefined;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&str_ptr));
                metadata.art_url = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:trackid")) {
            if (value_type == dbus.TYPE_STRING or value_type == dbus.TYPE_OBJECT_PATH) {
                var str_ptr: [*:0]const u8 = undefined;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&str_ptr));
                metadata.track_id = allocator.dupe(u8, mem.sliceTo(str_ptr, 0)) catch null;
            }
        } else if (mem.eql(u8, key, "mpris:length")) {
            if (value_type == dbus.TYPE_INT64) {
                var length: i64 = 0;
                dbus.dbus_message_iter_get_basic(&value_iter, @ptrCast(&length));
                metadata.length_us = length;
            }
        }

        _ = dbus.dbus_message_iter_next(&dict_iter);
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

test "listPlayers - integration" {
    const allocator = testing.allocator;

    const players = listPlayers(allocator) catch |err| {
        switch (err) {
            MprisError.ConnectionFailed, MprisError.CallFailed => return,
            else => return err,
        }
    };
    defer {
        for (players) |p| allocator.free(p);
        allocator.free(players);
    }

    for (players) |player| {
        try testing.expect(mem.startsWith(u8, player, MPRIS_PREFIX));
    }
}

test "getActivePlayer - integration" {
    const allocator = testing.allocator;

    var info = getActivePlayer(allocator) catch |err| {
        switch (err) {
            MprisError.ConnectionFailed, MprisError.CallFailed, MprisError.NoPlayers => return,
            else => return err,
        }
    };
    defer info.deinit(allocator);

    try testing.expect(info.name.len > 0);
    try testing.expect(info.volume >= 0.0);
    try testing.expect(info.volume <= 2.0);
    try testing.expect(info.position_us >= 0);
}
