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
const mem = std.mem;
const process = std.process;
const Io = std.Io;
const net = Io.net;
const Socket = net.Socket;
const IpAddress = net.IpAddress;
const HostName = net.HostName;
const File = Io.File;
const Clock = Io.Clock;
const Duration = Io.Duration;

const assert = std.debug.assert;

const Config = utils.Config;
const Json = utils.Json;
const Replacer = utils.Replacer;
const Watcher = utils.Watcher;

const PING_IDENTIFIER: u16 = 0xC0DE;

pub const ModuleConfig = struct {
    update_interval: i64 = 1,
    warning_threshold: ?i64 = 100,
    critical_threshold: ?i64 = 250,
    target_domain: []const u8 = "google.com",
    target_domain_ip_update_interval: i64 = 200,
    timeout: i64 = 3,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {latency}ms",
    tooltip: []const u8 = "Min: {min_latency:'ms'} {dot} Avg: {avg_latency:'ms'} {dot} Max: {max_latency:'ms':nl}Domain: {target:nl}IP: {ip} {dot} {next_ip_update:'s'}",
};

pub const PingError = error{
    Timeout,
    NetworkError,
};

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("ping", ModuleConfig);
    defer config.free(data);

    var watcher = try Watcher.init();
    defer watcher.deinit();

    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var resolved = try sysinfolib.resolveIP(gpa, io, data.target_domain);
    var last_update_ts: i64 = Clock.now(.boot, io).toSeconds();

    const local_addr: IpAddress = try IpAddress.parseIp4("0.0.0.0", 0);
    const socket = try local_addr.bind(io, .{ .mode = .dgram, .protocol = .icmp });
    defer socket.close(io);

    var target_addr: ?IpAddress = if (resolved) |ip_str| IpAddress.parseIp4(ip_str, 80) catch null else null;

    var min_latency: i64 = math.maxInt(i64);
    var max_latency: i64 = 0;
    var total_latency: i64 = 0;
    var ping_count: i64 = 0;

    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        const current = Clock.now(.boot, io);
        const now_s = current.toSeconds();

        if (resolved == null or (now_s - last_update_ts) >= data.target_domain_ip_update_interval) {
            if (try sysinfolib.resolveIP(gpa, io, data.target_domain)) |res| {
                resolved = res;
                last_update_ts = now_s;

                if (resolved) |ip_str| {
                    target_addr = IpAddress.parseIp4(ip_str, 80) catch null;
                }
            } else {
                // DNS resolution failed, retain former IP
            }
        }

        const target = target_addr orelse continue;

        const seconds_until_ip_update = data.target_domain_ip_update_interval - (now_s - last_update_ts);

        var ping_buffer: [64]u8 = @splat(0);
        var ping_target = target;
        const latency = ping(io, socket, &ping_target, &ping_buffer, data.timeout) catch {
            try json.set("text", @as([]const u8, "Timeout"));
            try json.set("tooltip", @as([]const u8, "Ping timeout"));
            try json.setClass("critical");
            try json.write(stdout);
            try stdout.flush();
            continue;
        };

        ping_count += 1;
        total_latency += latency;
        min_latency = @min(min_latency, latency);
        max_latency = @max(max_latency, latency);
        const avg_latency = @divTrunc(total_latency, ping_count);

        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKey("target", data.target_domain);
        try replacer.addKey("ip", resolved orelse "unresolved");
        try replacer.addKeyAny("next_ip_update", seconds_until_ip_update);
        try replacer.addKeyAny("latency", latency);
        try replacer.addKeyAny("min_latency", min_latency);
        try replacer.addKeyAny("avg_latency", avg_latency);
        try replacer.addKeyAny("max_latency", max_latency);

        const text_line = try replacer.render(data.text);
        defer replacer.free(text_line);

        const tooltip_line = try replacer.render(data.tooltip);
        defer replacer.free(tooltip_line);

        try json.set("text", text_line);
        try json.set("tooltip", tooltip_line);

        if (data.critical_threshold) |crit| {
            if (latency >= crit) {
                try json.setClass("critical");
            } else if (data.warning_threshold) |warn| {
                if (latency >= warn) {
                    try json.setClass("warning");
                } else {
                    try json.setClass("normal");
                }
            } else {
                try json.setClass("normal");
            }
        } else if (data.warning_threshold) |warn| {
            if (latency >= warn) {
                try json.setClass("warning");
            } else {
                try json.setClass("normal");
            }
        }

        try json.write(stdout);
        try stdout.flush();

        if (data.update_interval == 0) break;
    }
}

var next_sequence: u16 = 0;

pub fn ping(io: Io, socket: Socket, target_addr: *IpAddress, buffer: []u8, timeout: i64) !i64 {
    next_sequence +%= 1;
    const sequence = next_sequence;

    sysinfolib.createIcmpPacket(buffer);
    stampIcmpEcho(buffer, PING_IDENTIFIER, sequence);

    const raw_start = Clock.now(.boot, io);
    _ = socket.send(io, target_addr, buffer) catch return PingError.NetworkError;

    while (true) {
        const to: Io.Timeout = .{ .duration = .{ .clock = .boot, .raw = .fromSeconds(timeout) } };
        const n = socket.receiveTimeout(io, buffer, to) catch return PingError.Timeout;

        if (isMatchingEchoReply(n.data, sequence)) break;
    }

    const raw_end = Clock.now(.boot, io);

    const start = raw_start.toMilliseconds();
    const end = raw_end.toMilliseconds();

    return @intCast(@max(0, end - start));
}

fn stampIcmpEcho(buffer: []u8, identifier: u16, sequence: u16) void {
    assert(buffer.len >= 8);

    mem.writeInt(u16, buffer[2..4][0..2], 0, .big); // checksum, filled below
    mem.writeInt(u16, buffer[4..6][0..2], identifier, .big);
    mem.writeInt(u16, buffer[6..8][0..2], sequence, .big);
    mem.writeInt(u16, buffer[2..4][0..2], icmpChecksum(buffer), .big);
}

fn isMatchingEchoReply(reply: []const u8, sequence: u16) bool {    
    if (reply.len < 8) return false;
    if (reply[0] != 0) return false;

    const reply_seq = mem.readInt(u16, reply[6..8][0..2], .big);
    return reply_seq == sequence;
}

fn icmpChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;

    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);

    return @truncate(~sum);
}