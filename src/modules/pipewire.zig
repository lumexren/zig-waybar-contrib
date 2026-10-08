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
const Allocator = mem.Allocator;
const ascii = std.ascii;
const posix = std.posix;
const os = std.os;
const linux = os.linux;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

pub const ModuleConfig = struct {
    mode: []const u8 = "sink",
    icon_high: []const u8 = "󰕾",
    icon_medium: []const u8 = "󰖀",
    icon_low: []const u8 = "󰕿",
    icon_muted: []const u8 = "󰝟",
    icon_source: []const u8 = "󰍬",
    icon_source_muted: []const u8 = "󰍭",
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

    var connection: Connection = try .init(io, gpa, .Session, init.environ_map);
    defer connection.close();

    var pipewire: Pipewire = .init(io, init.environ_map, gpa, &connection);
    defer pipewire.deinit();

    // Initial render
    renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};

    var watcher = try Watcher.init();
    defer watcher.deinit();

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
                var fds = [_]posix.pollfd{
                    .{ .fd = pipe_file.handle, .events = posix.POLL.IN, .revents = 0 },
                    .{ .fd = watcher.sfd, .events = posix.POLL.IN, .revents = 0 },
                };

                const ret = posix.poll(&fds, -1) catch break;
                if (ret <= 0) break;

                var should_render = false;

                if ((fds[1].revents & posix.POLL.IN) != 0) {
                    var siginfo: linux.signalfd_siginfo = undefined;
                    _ = linux.read(watcher.sfd, @ptrCast(&siginfo), @sizeOf(linux.signalfd_siginfo));
                    should_render = true;
                }

                if ((fds[0].revents & posix.POLL.IN) != 0) {
                    const len = pipe_file.readStreaming(io, &.{line_buf[0..]}) catch break;
                    if (len == 0) break;
                    should_render = true;
                } else if ((fds[0].revents & (posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                    break;
                }

                if (should_render) {
                    renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};
                }
            }
        }
    }

    // Fallback polling if event stream closed unexpectedly
    while (true) : (_ = watcher.waitSeconds(1)) {
        renderOutput(stdout, gpa, &data, &json, &replacer, &pipewire) catch {};
    }
}

fn renderOutput(stdout: *Io.Writer, gpa: Allocator, data: *const ModuleConfig, json: *Json, replacer: *Replacer, pipewire: *Pipewire) !void {
    defer json.clear();
    defer replacer.clear();

    const is_source_mode = ascii.eqlIgnoreCase(data.mode, "source") or ascii.eqlIgnoreCase(data.mode, "microphone") or ascii.eqlIgnoreCase(data.mode, "input");

    var info = if (is_source_mode)
        pipewire.getSourceAudioInfo() catch |err| {
            try json.set("text", @as([]const u8, "Mic Error"));
            try json.set("tooltip", @as([]const u8, "PipeWire source unavailable"));
            try json.write(stdout);
            try stdout.flush();
            return err;
        }
    else
        pipewire.getAudioInfo() catch |err| {
            try json.set("text", @as([]const u8, "Audio Error"));
            try json.set("tooltip", @as([]const u8, "PipeWire audio unavailable"));
            try json.write(stdout);
            try stdout.flush();
            return err;
        };
    defer info.deinit(gpa);

    var maybe_source_info: ?Pipewire.PipewireInfo = null;
    if (!is_source_mode) {
        maybe_source_info = pipewire.getSourceAudioInfo() catch null;
    }
    defer if (maybe_source_info) |*si| si.deinit(gpa);

    const chosen_icon = if (is_source_mode)
        (if (info.muted) data.icon_source_muted else data.icon_source)
    else if (info.muted)
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

    if (maybe_source_info) |si| {
        const source_icon = if (si.muted) data.icon_source_muted else data.icon_source;
        try replacer.addKey("source_icon", source_icon);
        try replacer.addKeyAny("source_volume", si.volume);
        try replacer.addKeyAny("source_raw_volume", si.raw_volume);
        try replacer.addKey("source_node_name", si.node_name);
        try replacer.addKey("source_state", if (si.muted) "Muted" else "Active");
        try replacer.addKeyAny("source_muted", si.muted);
    } else {
        try replacer.addKey("source_icon", data.icon_source_muted);
        try replacer.addKeyAny("source_volume", @as(u8, 0));
        try replacer.addKeyAny("source_raw_volume", @as(f64, 0.0));
        try replacer.addKey("source_node_name", "N/A");
        try replacer.addKey("source_state", "N/A");
        try replacer.addKeyAny("source_muted", true);
    }

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
