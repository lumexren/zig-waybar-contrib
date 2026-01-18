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
// along with this program. If not, see <https://gnu.org/licenses>.

const std = @import("std");
const Io = std.Io;
const IpAddress = Io.net.IpAddress;
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;

// DNS Constants
const DNS_PORT: u16 = 53;
const DNS_TYPE_A: u16 = 1; // IPv4 address
const DNS_CLASS_IN: u16 = 1; // Internet

// Common DNS servers
const DNS_SERVERS = [_][]const u8{
    "9.9.9.9", // Quad9
    "94.140.14.14", // AdGuard
    "8.8.8.8", // Google
    "1.1.1.1", // Cloudflare
};

const NetworkError = error{
    InvalidResponse,
    InvalidHeader,
    InvalidLabel,
    InvalidCompression,
    NameTooLong,
    ResponseTooSmall,
    LabelTooLong,
    BufferTooSmall,
};

/// DNS Header structure (12 bytes)
const Header = struct {
    id: u16,
    flags: u16,
    qdcount: u16, // Question count
    ancount: u16, // Answer count
    nscount: u16, // Authority count
    arcount: u16, // Additional count

    fn toBytes(this: *const @This()) [12]u8 {
        var result: [12]u8 = undefined;
        mem.writeInt(u16, result[0..2], this.id, .big);
        mem.writeInt(u16, result[2..4], this.flags, .big);
        mem.writeInt(u16, result[4..6], this.qdcount, .big);
        mem.writeInt(u16, result[6..8], this.ancount, .big);
        mem.writeInt(u16, result[8..10], this.nscount, .big);
        mem.writeInt(u16, result[10..12], this.arcount, .big);
        return result;
    }

    fn fromBytes(bytes: []const u8) Header {
        return .{
            .id = mem.readInt(u16, bytes[0..2], .big),
            .flags = mem.readInt(u16, bytes[2..4], .big),
            .qdcount = mem.readInt(u16, bytes[4..6], .big),
            .ancount = mem.readInt(u16, bytes[6..8], .big),
            .nscount = mem.readInt(u16, bytes[8..10], .big),
            .arcount = mem.readInt(u16, bytes[10..12], .big),
        };
    }
};

/// Encode a domain name into DNS format (length-prefixed labels)
fn encodeDomain(domain: []const u8, buffer: []u8) !usize {
    var pos: usize = 0;
    var label_start: usize = 0;
    var i: usize = 0;

    while (i <= domain.len) : (i += 1) {
        if (i == domain.len or domain[i] == '.') {
            const label_len = i - label_start;
            if (label_len == 0) {
                label_start = i + 1;
                continue;
            }
            if (label_len > 63) return NetworkError.LabelTooLong;
            if (pos + 1 + label_len >= buffer.len) return NetworkError.BufferTooSmall;

            buffer[pos] = @intCast(label_len);
            pos += 1;
            @memcpy(buffer[pos .. pos + label_len], domain[label_start..i]);
            pos += label_len;
            label_start = i + 1;
        }
    }

    // Null terminator
    if (pos >= buffer.len) return NetworkError.BufferTooSmall;
    buffer[pos] = 0;
    pos += 1;

    return pos;
}

/// Build a DNS query packet
fn buildQuery(allocator: Allocator, domain: []const u8, query_id: u16) ![]u8 {
    var buffer = try allocator.alloc(u8, 512);

    // Build DNS header
    const header = Header{
        .id = query_id,
        .flags = 0x0100, // Standard query, recursion desired
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };

    const header_bytes = header.toBytes();
    @memcpy(buffer[0..12], &header_bytes);

    // Encode domain name
    var pos: usize = 12;
    const name_len = try encodeDomain(domain, buffer[pos..]);
    pos += name_len;

    // Add QTYPE (A record)
    mem.writeInt(u16, buffer[pos..][0..2], DNS_TYPE_A, .big);
    pos += 2;

    // Add QCLASS (IN)
    mem.writeInt(u16, buffer[pos..][0..2], DNS_CLASS_IN, .big);
    pos += 2;

    return buffer[0..pos];
}

/// Parse domain name from DNS response (handles compression)
fn parseDomain(response: []const u8, start_pos: usize, name_buf: []u8) !struct { name_len: usize, bytes_read: usize } {
    var pos = start_pos;
    var name_pos: usize = 0;
    var jumped = false;
    var jump_pos = start_pos;

    while (pos < response.len) {
        const len = response[pos];

        // Check for compression pointer
        if ((len & 0xC0) == 0xC0) {
            if (!jumped) jump_pos = pos + 2;
            jumped = true;

            if (pos + 1 >= response.len) return NetworkError.InvalidCompression;
            const offset = (@as(u16, len & 0x3F) << 8) | response[pos + 1];
            pos = offset;
            continue;
        }

        // End of domain name
        if (len == 0) {
            if (!jumped) jump_pos = pos + 1;
            break;
        }

        // Copy label
        if (name_pos > 0) {
            if (name_pos >= name_buf.len) return NetworkError.NameTooLong;
            name_buf[name_pos] = '.';
            name_pos += 1;
        }

        pos += 1;
        if (pos + len > response.len) return NetworkError.InvalidLabel;
        if (name_pos + len > name_buf.len) return NetworkError.NameTooLong;

        @memcpy(name_buf[name_pos .. name_pos + len], response[pos .. pos + len]);
        name_pos += len;
        pos += len;
    }

    return .{ .name_len = name_pos, .bytes_read = jump_pos - start_pos };
}

/// Extract IPv4 address from DNS response
fn parseRecord(response: []const u8) !?[4]u8 {
    if (response.len < 12) return NetworkError.ResponseTooSmall;

    const header = Header.fromBytes(response[0..12]);

    // Check if we got any answers
    if (header.ancount == 0) return null;

    // Skip the question section
    var pos: usize = 12;
    var name_buf: [256]u8 = undefined;

    // Skip question domain name
    const q_result = try parseDomain(response, pos, &name_buf);
    pos += q_result.bytes_read;

    // Skip QTYPE and QCLASS
    if (pos + 4 > response.len) return NetworkError.InvalidResponse;
    pos += 4;

    // Parse answer records
    var i: u16 = 0;
    while (i < header.ancount) : (i += 1) {
        // Parse answer name
        const a_result = try parseDomain(response, pos, &name_buf);
        pos += a_result.bytes_read;

        if (pos + 10 > response.len) return NetworkError.InvalidResponse;

        const record_type = mem.readInt(u16, response[pos..][0..2], .big);
        pos += 2;

        // Skip CLASS
        pos += 2;

        // Skip TTL
        pos += 4;

        const data_len = mem.readInt(u16, response[pos..][0..2], .big);
        pos += 2;

        // Check if this is an A record with IPv4 address
        if (record_type == DNS_TYPE_A and data_len == 4) {
            if (pos + 4 > response.len) return NetworkError.InvalidResponse;
            var ip: [4]u8 = undefined;
            @memcpy(&ip, response[pos .. pos + 4]);
            return ip;
        }

        // Skip this record's data
        pos += data_len;
        if (pos > response.len) return NetworkError.InvalidResponse;
    }

    return null;
}

/// Resolves a domain name to an IPv4 address string using pure Zig DNS resolution.
/// Returns null if resolution fails or no IPv4 address is found.
/// Caller owns the returned memory.
pub fn resolveIP(allocator: Allocator, io: Io, domain: []const u8) !?[]const u8 {
    var buffer: [64]u8 = undefined;
    Io.random(io, &buffer);

    // Generate random query ID
    const query_id: u16 = @truncate(buffer.len);

    // Build DNS query
    const query = try buildQuery(allocator, domain, query_id);

    // Try each DNS server
    for (DNS_SERVERS) |dns_server| {
        const dns_addr = IpAddress.parseIp4(dns_server, DNS_PORT) catch continue;
        const local_addr = IpAddress.parseIp4("0.0.0.0", 0) catch continue;

        const socket = local_addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch continue;
        defer socket.close(io);

        // Send query
        _ = socket.send(io, &dns_addr, query) catch continue;

        // Receive response
        var response_buf: [512]u8 = undefined;
        const recv_msg = socket.receive(io, &response_buf) catch continue;

        // Parse response
        if (parseRecord(response_buf[0..recv_msg.data.len])) |maybe_ip| {
            if (maybe_ip) |ip| return try fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
        } else |_| continue;
    }

    return null;
}

pub inline fn createIcmpPacket(buffer: []u8) void {
    @memset(buffer, 0);

    buffer[0] = 8;
    buffer[1] = 0;

    const checksum = calculateChecksum(buffer);
    buffer[2] = @truncate(checksum >> 8);
    buffer[3] = @truncate(checksum & 0xFF);
}

pub inline fn calculateChecksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;

    while (index + 3 < data.len) : (index += 4) {
        sum +%= @as(u32, data[index]) << 24 | @as(u32, data[index + 1]) << 16 | @as(u32, data[index + 2]) << 8 | @as(u32, data[index + 3]);
    }

    while (index < data.len) : (index += 1) {
        const shift = @as(u5, @intCast((data.len - index - 1) * 8));
        sum +%= @as(u32, data[index]) << shift;
    }

    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);

    return ~@as(u16, @truncate(sum));
}
