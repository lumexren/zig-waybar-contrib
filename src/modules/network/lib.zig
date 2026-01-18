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
const builtin = @import("builtin");
const core = @import("core");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const Duration = Io.Duration;
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const os = std.os;
const posix = std.posix;
const linux = os.linux;

const network = core.network;

pub const RouteInfo = struct {
    interface: []const u8,
    gateway: []const u8,
};

pub const Config = struct {
    update_interval: i64 = 1,
    icon: []const u8 = "",
    text: ?[]const u8 = null,
    tooltip: ?[]const u8 = null,
};

pub const NetworkError = error{
    NoDefaultRoute,
    InvalidRouteFormat,
    InvalidDevFormat,
    InterfaceNotFound,
};

/// Network traffic statistics for an interface
pub const NetworkStats = struct {
    rx_bytes: u64,
    tx_bytes: u64,
    timestamp: i64,

    pub fn calculateRates(old: NetworkStats, new: NetworkStats) struct { download: f64, upload: f64, total: f64 } {
        const time_diff = @as(f64, @floatFromInt(new.timestamp - old.timestamp));
        if (time_diff <= 0) return .{ .download = 0.0, .upload = 0.0, .total = 0.0 };

        const rx_diff = @as(f64, @floatFromInt(new.rx_bytes -| old.rx_bytes));
        const tx_diff = @as(f64, @floatFromInt(new.tx_bytes -| old.tx_bytes));

        return .{
            .download = rx_diff / time_diff,
            .upload = tx_diff / time_diff,
            .total = (rx_diff + tx_diff) / time_diff,
        };
    }
};

/// Network information including IPs and interface name
pub const NetworkInfo = struct {
    local_ip: []const u8,
    gateway_ip: []const u8,
    interface: []const u8,
};

/// Get the default network interface and gateway IP from /proc/net/route
pub fn getDefaultRoute(allocator: Allocator, io: Io) !RouteInfo {
    var file = try Io.Dir.openFileAbsolute(io, "/proc/net/route", .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var f_reader = file.reader(io, &.{});
    const bytes_read = try f_reader.interface.readSliceShort(&buffer);

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');

    // Skip header line
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var fields = mem.tokenizeAny(u8, line, " \t");

        const iface = fields.next() orelse continue;
        const dest = fields.next() orelse continue;
        const gateway = fields.next() orelse continue;

        // Check if this is the default route (destination = 00000000)
        if (mem.eql(u8, dest, "00000000")) {
            // Parse gateway IP (in hex, little-endian)
            const gw_val = try fmt.parseInt(u32, gateway, 16);

            // Convert from little-endian hex to IP address
            const gw_bytes = mem.nativeToLittle(u32, gw_val);
            const ip_bytes: [4]u8 = @bitCast(gw_bytes);

            const gateway_ip = try fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3],
            });

            return .{
                .interface = try allocator.dupe(u8, iface),
                .gateway = gateway_ip,
            };
        }
    }

    return NetworkError.NoDefaultRoute;
}

/// Get the default network interface and gateway IP with fallback values
pub fn getDefaultRouteOrFallback(allocator: Allocator, io: Io) !RouteInfo {
    return getDefaultRoute(allocator, io) catch {
        return .{
            .interface = try allocator.dupe(u8, "eth0"),
            .gateway = try allocator.dupe(u8, "0.0.0.0"),
        };
    };
}

/// Get the local IP address for a specific interface using ioctl
pub fn getLocalIP(allocator: Allocator, interface: []const u8) ![]const u8 {
    // Create a temporary socket for ioctl
    const sock = try __socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
    defer __close(sock);

    // Prepare ifreq structure
    var ifr: linux.ifreq = mem.zeroes(linux.ifreq);

    // Copy interface name (max 15 chars + null terminator)
    const name_len = @min(interface.len, 15);
    @memcpy(ifr.ifrn.name[0..name_len], interface[0..name_len]);
    ifr.ifrn.name[name_len] = 0;

    // Call ioctl to get interface address
    const SIOCGIFADDR = 0x8915;
    const result = linux.ioctl(sock, SIOCGIFADDR, @intFromPtr(&ifr));
    if (result != 0) {
        return try allocator.dupe(u8, "N/A");
    }

    // Extract IPv4 address from sockaddr_in
    const sockaddr_in = @as(*align(1) const posix.sockaddr.in, @ptrCast(&ifr.ifru.addr));
    const addr_bytes = @as(*const [4]u8, @ptrCast(&sockaddr_in.addr));

    // Format as dotted decimal string
    return try fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
        addr_bytes[0],
        addr_bytes[1],
        addr_bytes[2],
        addr_bytes[3],
    });
}

/// Read network statistics from /proc/net/dev for a specific interface
pub fn getNetworkStats(io: Io, interface: []const u8, timestamp: i64) !NetworkStats {
    var file = try Io.Dir.openFileAbsolute(io, "/proc/net/dev", .{ .mode = .read_only });
    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var f_reader = file.reader(io, &.{});
    const bytes_read = try f_reader.interface.readSliceShort(&buffer);

    var lines = mem.splitScalar(u8, buffer[0..bytes_read], '\n');

    // Skip header lines (first 2 lines)
    _ = lines.next();
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Format: "  interface: rx_bytes rx_packets ... tx_bytes tx_packets ..."
        const colon_pos = mem.indexOf(u8, line, ":") orelse continue;
        const iface = mem.trim(u8, line[0..colon_pos], " \t");

        if (!mem.eql(u8, iface, interface)) continue;

        // Parse the statistics after the colon
        var fields = mem.tokenizeAny(u8, line[colon_pos + 1 ..], " \t");

        const rx_bytes_str = fields.next() orelse return NetworkError.InvalidDevFormat;
        const rx_bytes = try fmt.parseInt(u64, rx_bytes_str, 10);

        // Skip 7 fields to get to tx_bytes
        var i: usize = 0;
        while (i < 7) : (i += 1) {
            _ = fields.next() orelse return NetworkError.InvalidDevFormat;
        }

        const tx_bytes_str = fields.next() orelse return NetworkError.InvalidDevFormat;
        const tx_bytes = try fmt.parseInt(u64, tx_bytes_str, 10);

        return NetworkStats{
            .rx_bytes = rx_bytes,
            .tx_bytes = tx_bytes,
            .timestamp = timestamp,
        };
    }

    return NetworkError.InterfaceNotFound;
}

/// Measure latency to a target IP using ICMP ping
pub fn ping(io: Io, buffer: []u8, target_ip: []const u8) !u64 {
    // Use ICMP ping similar to the ping module
    network.createIcmpPacket(buffer);

    // Default to port 0 for ICMP
    const addr = IpAddress.parseIp4(target_ip, 0) catch return 0;
    const local = IpAddress.parseIp4("0.0.0.0", 0) catch return 0;

    const socket = local.bind(io, .{ .mode = .dgram, .protocol = .icmp }) catch return 0;
    defer socket.close(io);

    const start = try Io.Clock.now(.boot, io);

    // Send ICMP packet
    _ = socket.send(io, &addr, buffer) catch return 0;

    // Receive reply (blocking, but we rely on system timeout or non-blocking if configured,
    // here we just hope for the best or it blocks until reply/timeout)
    // Note: In a real implementation we might want to set a timeout on the socket if possible,
    // or use async/await if supported. Since setTimeout is missing, we rely on the OS default or non-blocking IO if we set it.
    // For now, we just call receive.
    _ = socket.receive(io, buffer) catch return 0;

    const end = try Io.Clock.now(.boot, io);

    const start_ms = Duration.fromNanoseconds(start.nanoseconds).toMilliseconds();
    const end_ms = Duration.fromNanoseconds(end.nanoseconds).toMilliseconds();

    return @intCast(@max(0, end_ms - start_ms));
}

/// This was backported from the
/// https://codeberg.org/ziglang/zig/src/commit/d10a730480fef4d35c951881948baed991a803de/lib/std/posix.zig commit.
///
/// This is a temporary solution and will be removed soon.
pub const system = if (builtin.link_libc)
    std.c
else switch (builtin.os.tag) {
    .linux => linux,
    .plan9 => std.os.plan9,
    else => struct {
        pub const pid_t = void;
        pub const pollfd = void;
        pub const fd_t = void;
        pub const uid_t = void;
        pub const gid_t = void;
        pub const mode_t = u0;
        pub const nlink_t = u0;
        pub const ino_t = void;
        pub const IFNAMESIZE = {};
        pub const SIG = void;
    },
};

/// This function was backported from the
/// https://codeberg.org/ziglang/zig/src/commit/d10a730480fef4d35c951881948baed991a803de/lib/std/posix.zig commit.
///
/// This is a temporary solution and will be removed soon.
pub fn __socket(domain: u32, socket_type: u32, protocol: u32) !posix.socket_t {
    const have_sock_flags = !builtin.target.os.tag.isDarwin() and builtin.os.tag != .haiku;
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, system.SOCK.NONBLOCK | system.SOCK.CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (system.errno(rc)) {
        .SUCCESS => {
            const fd: system.fd_t = @intCast(rc);
            errdefer __close(fd);
            if (!have_sock_flags) {
                try __setSockFlags(fd, socket_type);
            }
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyUnsupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// This function was backported from the
/// https://codeberg.org/ziglang/zig/src/commit/d10a730480fef4d35c951881948baed991a803de/lib/std/posix.zig commit.
///
/// This is a temporary solution and will be removed soon.
pub fn __close(fd: system.fd_t) void {
    if (builtin.os.tag == .windows) {
        return os.windows.CloseHandle(fd);
    }
    if (builtin.os.tag == .wasi and !builtin.link_libc) {
        _ = std.os.wasi.fd_close(fd);
        return;
    }
    switch (system.errno(system.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => return,
    }
}

/// This function was backported from the
/// https://codeberg.org/ziglang/zig/src/commit/d10a730480fef4d35c951881948baed991a803de/lib/std/posix.zig commit.
///
/// This is a temporary solution and will be removed soon.
fn __setSockFlags(sock: system.socket_t, flags: u32) !void {
    if ((flags & system.SOCK.CLOEXEC) != 0) {
        if (builtin.os.tag == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = system.fcntl(sock, system.F.GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fd_flags |= system.FD_CLOEXEC;
            _ = system.fcntl(sock, system.F.SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & system.SOCK.NONBLOCK) != 0) {
        if (builtin.os.tag == .windows) {
            var mode: c_ulong = 1;
            if (os.windows.ws2_32.ioctlsocket(sock, os.windows.ws2_32.FIONBIO, &mode) == os.windows.ws2_32.SOCKET_ERROR) {
                switch (os.windows.ws2_32.WSAGetLastError()) {
                    .NOTINITIALISED => unreachable,
                    .ENETDOWN => return error.NetworkDown,
                    .ENOTSOCK => return error.FileDescriptorNotASocket,
                    // TODO: handle more errors
                    else => |err| return os.windows.unexpectedWSAError(err),
                }
            }
        } else {
            var fl_flags = system.fcntl(sock, system.F.GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fl_flags |= 1 << @bitOffsetOf(system.O, "NONBLOCK");
            _ = system.fcntl(sock, system.F.SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
}
