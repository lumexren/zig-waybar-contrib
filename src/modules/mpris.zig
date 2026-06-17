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

const mpris = @import("sysinfo").mpris;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const math = std.math;
const fmt = std.fmt;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 18,
    icon: []const u8 = "",
    icon_playing: []const u8 = "",
    icon_paused: []const u8 = "",
    icon_stopped: []const u8 = "",
    text: []const u8 = "{icon}  {title} {dot} {artist}",
    text_max_length: u16 = 256,
    tooltip: []const u8 = "{player_name}: {status}{nl}{title} - {artist}{nl}Album: {album}{nl}{position} / {length}",
    no_player_text: []const u8 = "No player",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, gpa);
    const config = try cfg.load("mpris", ModuleConfig);
    defer cfg.free(config);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        try replacer.addCommonPlaceholders();

        const player_info = mpris.getActivePlayer(gpa) catch |err| {
            switch (err) {
                mpris.MprisError.NoPlayers, mpris.MprisError.ConnectionFailed => {
                    try replacer.addKey("icon", config.icon);
                    try json.set("text", config.no_player_text);
                    try json.set("tooltip", @as([]const u8, "No MPRIS player available"));
                    try json.set("class", @as([]const u8, "no-player"));

                    try json.write(stdout);
                    try stdout.flush();

                    try waybar.updateOrRefresh();
                    continue;
                },
                else => return err,
            }
        };
        defer {
            var info = player_info;
            info.deinit(gpa);
        }

        // Status icon
        const status_icon = switch (player_info.status) {
            .playing => config.icon_playing,
            .paused => config.icon_paused,
            .stopped => config.icon_stopped,
        };

        try replacer.addKey("icon", status_icon);
        try replacer.addKey("player_name", player_info.name);
        try replacer.addKey("identity", player_info.identity orelse player_info.name);
        const status_str: []const u8 = player_info.status.toString();
        const loop_status_str: []const u8 = player_info.loop_status.toString();
        try replacer.addKey("status", status_str);
        try replacer.addKey("loop_status", loop_status_str);
        try replacer.addKeyAny("shuffle", player_info.shuffle);
        try replacer.addKeyAny("volume", @as(i64, @intFromFloat(@round(player_info.volume * 100))));

        // Metadata
        try replacer.addKey("title", player_info.metadata.title orelse "Unknown");
        try replacer.addKey("artist", player_info.metadata.artist orelse "Unknown");
        try replacer.addKey("album", player_info.metadata.album orelse "Unknown");
        try replacer.addKey("art_url", player_info.metadata.art_url orelse "");

        // Convert position and length from microseconds to MM:SS
        const position_secs = @divFloor(player_info.position_us, 1_000_000);
        const position_min = @divFloor(position_secs, 60);
        const position_sec = @mod(position_secs, 60);

        var position_buf: [16]u8 = undefined;
        const position_str = fmt.bufPrint(&position_buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(position_min)), @as(u64, @intCast(position_sec)) }) catch "00:00";
        try replacer.addKey("position", position_str);
        try replacer.addKeyAny("position_us", player_info.position_us);

        if (player_info.metadata.length_us) |length_us| {
            const length_secs = @divFloor(length_us, 1_000_000);
            const length_min = @divFloor(length_secs, 60);
            const length_sec = @mod(length_secs, 60);

            var length_buf: [16]u8 = undefined;
            const length_str = fmt.bufPrint(&length_buf, "{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(length_min)), @as(u64, @intCast(length_sec)) }) catch "00:00";
            try replacer.addKey("length", length_str);
            try replacer.addKeyAny("length_us", length_us);
        } else {
            try replacer.addKey("length", "--:--");
            try replacer.addKeyAny("length_us", @as(i64, 0));
        }

        // Capabilities
        try replacer.addKeyAny("can_control", player_info.can_control);
        try replacer.addKeyAny("can_go_next", player_info.can_go_next);
        try replacer.addKeyAny("can_go_previous", player_info.can_go_previous);
        try replacer.addKeyAny("can_play", player_info.can_play);
        try replacer.addKeyAny("can_pause", player_info.can_pause);
        try replacer.addKeyAny("can_seek", player_info.can_seek);

        var text_line = try replacer.render(config.text);
        defer replacer.free(text_line);

        if (config.text_max_length != 0 and text_line.len > config.text_max_length)
            text_line = text_line[0..config.text_max_length];

        const tooltip_line = try replacer.render(config.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);
        try json.set("class", status_str);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}
