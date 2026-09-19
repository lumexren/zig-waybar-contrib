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

const Pipewire = @import("sysinfo").Pipewire;

const plume = @import("plume");
const Connection = plume.Connection;

const std = @import("std");
const utils = @import("utils");
const Io = std.Io;
const File = Io.File;
const process = std.process;
const mem = std.mem;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    icon_high: []const u8 = "󰕾",
    icon_medium: []const u8 = "󰖀",
    icon_low: []const u8 = "󰕿",
    icon_muted: []const u8 = "󰝟",
    text: []const u8 = "{icon}  {volume:'%'}",
    tooltip: []const u8 = "Device: {node_name}{nl}Volume: {volume:'%'}{nl}State: {state}",
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("pipewire", ModuleConfig);
    defer config.free(data);

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var connection: Connection = try .init(io, gpa, init.environ_map, .Session);
    defer connection.close();

    var pipewire: Pipewire = .init(io, init.environ_map, gpa, &connection);
    defer pipewire.deinit();

    // Initial render
    renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};

    // Event-driven: subscribe to pactl subscribe / pw-mon event stream
    var child = pipewire.subscribeViaProcess() catch null;
    defer if (child) |*c| {
        c.kill(io);
        _ = c.wait(io) catch {};
    };

    if (child) |*c| {
        if (c.stdout) |pipe_file| {
            var line_buf: [1024]u8 = undefined;
            while (true) {
                const len = pipe_file.readStreaming(io, &.{line_buf[0..]}) catch break;
                if (len == 0) break;
                renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};
            }
        }
    }

    var watcher = try Watcher.init();
    defer watcher.deinit();

    // Fallback polling if event stream closed unexpectedly
    while (true) : (_ = watcher.waitSeconds(1)) {
        renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};
    }
}

fn renderOutput(stdout: *Io.Writer, gpa: std.mem.Allocator, data: *const ModuleConfig, json: *Json, replacer: *Replacer, pipewire: *Pipewire) !void {
    defer json.clear();
    defer replacer.clear();

    var info = pipewire.getAudioInfo() catch |err| {
        try json.set("text", @as([]const u8, "Audio Error"));
        try json.set("tooltip", @as([]const u8, "PipeWire audio unavailable"));
        try json.write(stdout);
        try stdout.flush();
        return err;
    };
    defer info.deinit(gpa);

    const chosen_icon = if (info.muted)
        data.icon_muted
    else if (info.volume > 60)
        data.icon_high
    else if (info.volume > 25)
        data.icon_medium
    else
        data.icon_low;

    const state_str: []const u8 = if (info.muted) "Muted" else "Active";

    try replacer.addCommonPlaceholders();
    try replacer.addKey("icon", chosen_icon);
    try replacer.addKeyAny("volume", info.volume);
    try replacer.addKeyAny("raw_volume", info.raw_volume);
    try replacer.addKey("node_name", info.node_name);
    try replacer.addKey("state", state_str);
    try replacer.addKeyAny("is_muted", info.muted);

    const text_line = try replacer.render(data.text);
    defer replacer.free(text_line);

    const tooltip_line = try replacer.render(data.tooltip);
    defer replacer.free(tooltip_line);

    try json.set("text", text_line);
    try json.set("tooltip", tooltip_line);
    try json.set("percentage", info.volume);
    try json.set("class", @as([]const u8, if (info.muted) "muted" else "active"));

    try json.write(stdout);
    try stdout.flush();
}
