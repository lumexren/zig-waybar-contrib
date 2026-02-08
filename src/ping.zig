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
// along with this program. If not, see <https://gnu.org/licenses/>.

const sysinfo = @import("sysinfo").network;
const sysinfolib = sysinfo.lib;

const std = @import("std");
const utils = @import("utils");
const math = std.math;
const process = std.process;
const Io = std.Io;
const net = Io.net;
const Socket = net.Socket;
const IpAddress = net.IpAddress;
const HostName = net.HostName;
const File = Io.File;
const Clock = Io.Clock;
const Duration = Io.Duration;

const Config = utils.Config;
const Json = utils.Json;
const Waybar = utils.Waybar;
const Replacer = utils.Replacer;
const Output = utils.Output;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    signal_number: u8 = 15,
    target_domain: []const u8 = "google.com",
    target_domain_ip_update_interval: i64 = 200,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {latency}ms",
    tooltip: []const u8 = "Min: {min_latency}ms {dot} Avg: {avg_latency}ms {dot} Max: {max_latency}ms{nl}Domain: {target}{nl}IP: {ip} {dot} {next_ip_update}s",
};

pub const PingError = error{
    Timeout,
    NetworkError,
};

pub fn main(init: process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var cfg: Config = .init(io, init.environ_map, allocator);
    const config = try cfg.load("ping", ModuleConfig);

    var json: Json = .init(allocator);
    defer json.deinit();

    var replacer: Replacer = .init(allocator);
    defer replacer.deinit();

    var waybar: Waybar = try .init(io, .{ .signal_number = config.signal_number });

    var resolved = try sysinfolib.resolveIP(allocator, io, config.target_domain);
    var last_update_ts: i64 = 0;

    const local_addr: IpAddress = try .parseIp4("0.0.0.0", 0);
    const socket = try local_addr.bind(io, .{ .mode = .dgram, .protocol = .icmp });
    defer socket.close(io);

    var target_addr: IpAddress = try .parseIp4(resolved.?, 80);

    // Latency statistics
    var min_latency: i64 = math.maxInt(i64);
    var max_latency: i64 = 0;
    var total_latency: i64 = 0;
    var ping_count: i64 = 0;

    while (true) : (try io.sleep(.fromSeconds(config.update_interval), .boot)) {
        defer json.clear();
        defer replacer.clear();

        const current = Clock.now(.boot, io);
        const now_s = current.toSeconds();

        if (resolved == null or (now_s - last_update_ts) >= config.target_domain_ip_update_interval) {
            resolved = try sysinfolib.resolveIP(allocator, io, config.target_domain);
            last_update_ts = now_s;

            target_addr = try .parseIp4(resolved.?, 80);
        }

        const seconds_until_ip_update = config.target_domain_ip_update_interval - (now_s - last_update_ts);

        var ping_buffer: [64]u8 = undefined;
        const latency = ping(io, socket, &target_addr, &ping_buffer) catch continue;

        // Update statistics
        ping_count += 1;
        total_latency += latency;
        min_latency = @min(min_latency, latency);
        max_latency = @max(max_latency, latency);
        const avg_latency = @divTrunc(total_latency, ping_count);

        try Output.addCommonPlaceholders(&replacer);
        try replacer.addKey("icon", config.icon);
        try replacer.addKey("target", config.target_domain);
        try replacer.addKey("ip", resolved.?);
        try replacer.addKeyAny("next_ip_update", seconds_until_ip_update);
        try replacer.addKeyAny("latency", latency);
        try replacer.addKeyAny("min_latency", min_latency);
        try replacer.addKeyAny("avg_latency", avg_latency);
        try replacer.addKeyAny("max_latency", max_latency);

        const text_line = try replacer.render(config.text);
        try json.set("text", text_line);

        const tooltip_line = try replacer.render(config.tooltip);
        try json.set("tooltip", tooltip_line);

        try json.write(stdout);
        try stdout.flush();

        try waybar.updateOrRefresh();
    }
}

pub fn ping(io: Io, socket: Socket, target_addr: *IpAddress, buffer: []u8) !i64 {
    sysinfolib.createIcmpPacket(buffer);

    const raw_start = Clock.now(.boot, io);

    _ = try socket.send(io, target_addr, buffer);
    _ = try socket.receive(io, buffer);

    const raw_end = Clock.now(.boot, io);

    const start = Duration.fromNanoseconds(raw_start.nanoseconds).toMilliseconds();
    const end = Duration.fromNanoseconds(raw_end.nanoseconds).toMilliseconds();

    return @intCast(@max(0, end - start));
}
