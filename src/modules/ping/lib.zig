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
// along with this program. If not, see <https://gnu.org/licenses/>.

const std = @import("std");
const core = @import("core");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const Clock = Io.Clock;
const Duration = Io.Duration;
const mem = std.mem;

const network = core.network;

pub const Config = struct {
    target_domain: []const u8 = "google.com",
    update_interval: i64 = 1,
    ip_update_interval: u64 = 120,
    icon: []const u8 = "",
    text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

pub const PingError = error{
    Timeout,
    NetworkError,
};

pub fn ping(io: Io, buffer: []u8, ip: []const u8) !i64 {
    network.createIcmpPacket(buffer);

    const target_addr: IpAddress = try .parseIp4(ip, 80);
    const local_addr: IpAddress = try .parseIp4("0.0.0.0", 0);

    const socket = try local_addr.bind(io, .{ .mode = .dgram, .protocol = .icmp });

    defer socket.close(io);

    const raw_start = try Clock.now(.boot, io);

    _ = try socket.send(io, &target_addr, buffer);
    _ = try socket.receive(io, buffer);

    const raw_end = try Clock.now(.boot, io);

    const start = Duration.fromNanoseconds(raw_start.nanoseconds).toMilliseconds();
    const end = Duration.fromNanoseconds(raw_end.nanoseconds).toMilliseconds();

    return @intCast(@max(0, end - start));
}
