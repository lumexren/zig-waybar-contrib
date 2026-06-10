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

pub const lib = @import("lib.zig");

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const linux = std.os.linux;

const SIOCGIFADDR: u32 = 0x8915;
const ROUTE_PATH = "/proc/net/route";
const DEV_PATH = "/proc/net/dev";

pub const NetworkError = error{
    NoDefaultRoute,
    InvalidRouteFormat,
    InvalidDevFormat,
    InterfaceNotFound,
};

/// Default route information.
pub const RouteInfo = struct {
    interface: []const u8,
    gateway: []const u8,
};

/// Network traffic statistics.
pub const NetworkStats = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    timestamp: i64,

    /// Calculate rates (bytes/sec) between two samples.
    pub fn calculateRates(old: @This(), new: @This()) struct { download: f64, upload: f64, total: f64 } {
        const dt = new.timestamp - old.timestamp;
        if (dt <= 0) return .{ .download = 0.0, .upload = 0.0, .total = 0.0 };

        const t: f64 = @floatFromInt(dt);
        const rx: f64 = @floatFromInt(new.rx_bytes -| old.rx_bytes);
        const tx: f64 = @floatFromInt(new.tx_bytes -| old.tx_bytes);

        return .{ .download = rx / t, .upload = tx / t, .total = (rx + tx) / t };
    }
};

/// Formats an IPv4 address from 4 bytes.
fn formatIPv4(allocator: Allocator, bytes: [4]u8) ![]const u8 {
    return fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

/// Reads file content into buffer.
fn readFile(io: Io, path: []const u8, buffer: []u8) ![]const u8 {
    var file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const n = try reader.interface.readSliceShort(buffer);
    return buffer[0..n];
}

/// Get default network interface and gateway from /proc/net/route.
pub fn getDefaultRoute(io: Io, allocator: Allocator) !RouteInfo {
    var buffer: [4096]u8 = undefined;
    const content = try readFile(io, ROUTE_PATH, &buffer);

    var lines = mem.splitScalar(u8, content, '\n');
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = mem.tokenizeAny(u8, line, " \t");
        const iface = fields.next() orelse continue;
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;

        if (!mem.eql(u8, dest, "00000000")) continue;

        const gw_hex = try fmt.parseInt(u32, gateway, 16);
        const gw_bytes: [4]u8 = @bitCast(mem.nativeToLittle(u32, gw_hex));

        return .{
            .interface = try allocator.dupe(u8, iface),
            .gateway = try formatIPv4(allocator, gw_bytes),
        };
    }

    return NetworkError.NoDefaultRoute;
}

/// Get local IP address for an interface using ioctl.
pub fn getLocalIP(allocator: Allocator, interface: []const u8) ![]const u8 {
    const sock_result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (sock_result < 0) return allocator.dupe(u8, "N/A");

    const sock: linux.fd_t = @intCast(sock_result);
    defer _ = linux.close(sock);

    var ifr: linux.ifreq = mem.zeroes(linux.ifreq);
    const len = @min(interface.len, 15);
    @memcpy(ifr.ifrn.name[0..len], interface[0..len]);

    if (linux.ioctl(sock, SIOCGIFADDR, @intFromPtr(&ifr)) != 0) return allocator.dupe(u8, "N/A");

    const addr: *const linux.sockaddr.in = @ptrCast(@alignCast(&ifr.ifru.addr));
    return formatIPv4(allocator, @bitCast(addr.addr));
}

/// Read network statistics from /proc/net/dev.
pub fn getNetworkStats(io: Io, interface: []const u8, timestamp: i64) !NetworkStats {
    var buffer: [8192]u8 = undefined;
    const content = try readFile(io, DEV_PATH, &buffer);

    var lines = mem.splitScalar(u8, content, '\n');
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.indexOfScalar(u8, line, ':') orelse continue;
        const iface = mem.trim(u8, line[0..colon], " \t");

        if (!mem.eql(u8, iface, interface)) continue;

        var fields = mem.tokenizeAny(u8, line[colon + 1 ..], " \t");

        const rx_bytes = try fmt.parseInt(u64, fields.next() orelse return NetworkError.InvalidDevFormat, 10);

        inline for (0..7) |_| _ = fields.next() orelse return NetworkError.InvalidDevFormat;

        const tx_bytes = try fmt.parseInt(u64, fields.next() orelse return NetworkError.InvalidDevFormat, 10);

        return .{ .rx_bytes = rx_bytes, .tx_bytes = tx_bytes, .timestamp = timestamp };
    }

    return NetworkError.InterfaceNotFound;
}

// Tests

const testing = std.testing;

test "NetworkStats.calculateRates - normal" {
    const old = NetworkStats{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 0 };
    const new = NetworkStats{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 1 };
    const rates = NetworkStats.calculateRates(old, new);

    try testing.expectApproxEqAbs(@as(f64, 1000.0), rates.download, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1000.0), rates.upload, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 2000.0), rates.total, 0.001);
}

test "NetworkStats.calculateRates - zero/negative time" {
    const same_time = NetworkStats.calculateRates(
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 5 },
        .{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 5 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), same_time.total, 0.001);

    const negative = NetworkStats.calculateRates(
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 10 },
        .{ .rx_bytes = 2000, .tx_bytes = 1500, .timestamp = 5 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), negative.total, 0.001);
}

test "NetworkStats.calculateRates - counter wraparound" {
    const rates = NetworkStats.calculateRates(
        .{ .rx_bytes = 5000, .tx_bytes = 3000, .timestamp = 0 },
        .{ .rx_bytes = 1000, .tx_bytes = 500, .timestamp = 1 },
    );
    try testing.expectApproxEqAbs(@as(f64, 0.0), rates.total, 0.001);
}

test "getDefaultRoute" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    try testing.expect(route.interface.len > 0);
    try testing.expect(route.gateway.len > 0);
}

test "getLocalIP - valid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    const ip = try getLocalIP(testing.allocator, route.interface);
    defer testing.allocator.free(ip);

    try testing.expect(ip.len > 0);
}

test "getLocalIP - invalid interface" {
    const ip = try getLocalIP(testing.allocator, "nonexistent_iface");
    defer testing.allocator.free(ip);
    try testing.expectEqualStrings("N/A", ip);
}

test "getNetworkStats - valid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const route = getDefaultRoute(io, testing.allocator) catch |err| {
        if (err == error.FileNotFound or err == NetworkError.NoDefaultRoute) return;
        return err;
    };
    defer testing.allocator.free(route.interface);
    defer testing.allocator.free(route.gateway);

    const stats = getNetworkStats(io, route.interface, 42) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try testing.expect(stats.timestamp == 42);
}

test "getNetworkStats - invalid interface" {
    var threaded: Io.Threaded = .init_single_threaded;
    try testing.expectError(
        NetworkError.InterfaceNotFound,
        getNetworkStats(threaded.io(), "nonexistent", 0),
    );
}
