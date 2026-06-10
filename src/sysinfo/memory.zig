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

const std = @import("std");
const StaticStringMap = std.StaticStringMap;
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Dir = Io.Dir;

const KB: u64 = 1024;
const MEMINFO_PATH = "/proc/meminfo";

pub const MemoryError = error{InvalidData};

/// Complete memory information.
pub const MemoryInfo = struct {
    percentage: u64 = 0,
    physical: PhysicalMemoryInfo = .{},
    swap: SwapMemoryInfo = .{},
};

/// Physical memory statistics from /proc/meminfo.
pub const PhysicalMemoryInfo = struct {
    // Basic
    total: u64 = 0,
    free: u64 = 0,
    available: u64 = 0,
    used: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    shared: u64 = 0,

    // Activity
    active: u64 = 0,
    inactive: u64 = 0,
    active_anon: u64 = 0,
    inactive_anon: u64 = 0,
    active_file: u64 = 0,
    inactive_file: u64 = 0,

    // Anonymous / file-backed
    anon_pages: u64 = 0,
    mapped: u64 = 0,

    // Slab
    slab: u64 = 0,
    slab_reclaimable: u64 = 0,
    slab_unreclaimable: u64 = 0,
    kernel_reclaimable: u64 = 0,

    // Kernel / low-level
    kernel_stack: u64 = 0,
    page_tables: u64 = 0,
    sec_page_tables: u64 = 0,
    percpu: u64 = 0,

    // Writeback / state
    dirty: u64 = 0,
    writeback: u64 = 0,
    writeback_tmp: u64 = 0,
    unevictable: u64 = 0,
    mlocked: u64 = 0,

    // Huge / special pages
    anon_huge_pages: u64 = 0,
    file_huge_pages: u64 = 0,
    file_pmd_mapped: u64 = 0,
    shmem_huge_pages: u64 = 0,
    shmem_pmd_mapped: u64 = 0,
    hugetlb: u64 = 0,
    hugepages_size: u64 = 0,

    // Direct map
    direct_map_4k: u64 = 0,
    direct_map_2m: u64 = 0,
    direct_map_1g: u64 = 0,

    // Misc
    vmalloc_total: u64 = 0,
    vmalloc_used: u64 = 0,
    vmalloc_chunk: u64 = 0,
    hardware_corrupted: u64 = 0,
    bounce: u64 = 0,
    nfs_unstable: u64 = 0,
    cma_total: u64 = 0,
    cma_free: u64 = 0,
    unaccepted: u64 = 0,
    balloon: u64 = 0,
};

/// Swap memory statistics.
pub const SwapMemoryInfo = struct {
    total: u64 = 0,
    free: u64 = 0,
    used: u64 = 0,
    cached: u64 = 0,

    // Zswap
    zswap: u64 = 0,
    zswapped: u64 = 0,

    // Commit
    commit_limit: u64 = 0,
    committed_as: u64 = 0,
};

const Field = enum {
    // Physical – basic
    MemTotal,
    MemFree,
    MemAvailable,
    Buffers,
    Cached,
    Shmem,
    // Physical – activity
    Active,
    Inactive,
    Active_anon,
    Inactive_anon,
    Active_file,
    Inactive_file,
    // Physical – anonymous / file-backed
    AnonPages,
    Mapped,
    // Physical – slab
    Slab,
    SReclaimable,
    SUnreclaim,
    KReclaimable,
    // Physical – kernel / low-level
    KernelStack,
    PageTables,
    SecPageTables,
    Percpu,
    // Physical – writeback / state
    Dirty,
    Writeback,
    WritebackTmp,
    Unevictable,
    Mlocked,
    // Physical – huge / special pages
    AnonHugePages,
    FileHugePages,
    FilePmdMapped,
    ShmemHugePages,
    ShmemPmdMapped,
    Hugetlb,
    Hugepagesize,
    // Physical – direct map
    DirectMap4k,
    DirectMap2M,
    DirectMap1G,
    // Physical – misc
    VmallocTotal,
    VmallocUsed,
    VmallocChunk,
    HardwareCorrupted,
    Bounce,
    NFS_Unstable,
    CmaTotal,
    CmaFree,
    Unaccepted,
    Balloon,
    // Swap
    SwapTotal,
    SwapFree,
    SwapCached,
    Zswap,
    Zswapped,
    CommitLimit,
    Committed_AS,
};

const field_map: StaticStringMap(Field) = .initComptime(.{
    // Physical – basic
    .{ "MemTotal", .MemTotal },                   .{ "MemFree", .MemFree },
    .{ "MemAvailable", .MemAvailable },           .{ "Buffers", .Buffers },
    .{ "Cached", .Cached },                       .{ "Shmem", .Shmem },
    // Physical – activity
    .{ "Active", .Active },                       .{ "Inactive", .Inactive },
    .{ "Active(anon)", .Active_anon },            .{ "Inactive(anon)", .Inactive_anon },
    .{ "Active(file)", .Active_file },            .{ "Inactive(file)", .Inactive_file },
    // Physical – anonymous / file-backed
    .{ "AnonPages", .AnonPages },                 .{ "Mapped", .Mapped },
    // Physical – slab
    .{ "Slab", .Slab },                           .{ "SReclaimable", .SReclaimable },
    .{ "SUnreclaim", .SUnreclaim },               .{ "KReclaimable", .KReclaimable },
    // Physical – kernel / low-level
    .{ "KernelStack", .KernelStack },             .{ "PageTables", .PageTables },
    .{ "SecPageTables", .SecPageTables },         .{ "Percpu", .Percpu },
    // Physical – writeback / state
    .{ "Dirty", .Dirty },                         .{ "Writeback", .Writeback },
    .{ "WritebackTmp", .WritebackTmp },           .{ "Unevictable", .Unevictable },
    .{ "Mlocked", .Mlocked },
    // Physical – huge / special pages
                        .{ "AnonHugePages", .AnonHugePages },
    .{ "FileHugePages", .FileHugePages },         .{ "FilePmdMapped", .FilePmdMapped },
    .{ "ShmemHugePages", .ShmemHugePages },       .{ "ShmemPmdMapped", .ShmemPmdMapped },
    .{ "Hugetlb", .Hugetlb },                     .{ "Hugepagesize", .Hugepagesize },
    // Physical – direct map
    .{ "DirectMap4k", .DirectMap4k },             .{ "DirectMap2M", .DirectMap2M },
    .{ "DirectMap1G", .DirectMap1G },
    // Physical – misc
                .{ "VmallocTotal", .VmallocTotal },
    .{ "VmallocUsed", .VmallocUsed },             .{ "VmallocChunk", .VmallocChunk },
    .{ "HardwareCorrupted", .HardwareCorrupted }, .{ "Bounce", .Bounce },
    .{ "NFS_Unstable", .NFS_Unstable },           .{ "CmaTotal", .CmaTotal },
    .{ "CmaFree", .CmaFree },                     .{ "Unaccepted", .Unaccepted },
    .{ "Balloon", .Balloon },
    // Swap
                        .{ "SwapTotal", .SwapTotal },
    .{ "SwapFree", .SwapFree },                   .{ "SwapCached", .SwapCached },
    .{ "Zswap", .Zswap },                         .{ "Zswapped", .Zswapped },
    .{ "CommitLimit", .CommitLimit },             .{ "Committed_AS", .Committed_AS },
});

/// Parses a value from /proc/meminfo (e.g., "12345 kB" -> bytes).
pub fn parseValue(s: []const u8) !u64 {
    var it = mem.tokenizeAny(u8, s, " \t");
    const num = it.next() orelse return MemoryError.InvalidData;
    const value = try fmt.parseUnsigned(u64, num, 10);

    return if (it.next()) |u| if (mem.eql(u8, u, "kB")) value * KB else value else value;
}

/// Fetches memory information from /proc/meminfo.
pub fn fetchMemoryInfo(io: Io) !MemoryInfo {
    var info: MemoryInfo = .{};
    var buffer: [4096]u8 = undefined;

    var file = try Dir.openFileAbsolute(io, MEMINFO_PATH, .{ .mode = .read_only });
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const n = try reader.interface.readSliceShort(&buffer);

    var lines = mem.splitScalar(u8, buffer[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const field = field_map.get(line[0..colon]) orelse continue;
        const value = try parseValue(mem.trimStart(u8, line[colon + 1 ..], " \t"));

        switch (field) {
            // Physical – basic
            .MemTotal => info.physical.total = value,
            .MemFree => info.physical.free = value,
            .MemAvailable => info.physical.available = value,
            .Buffers => info.physical.buffers = value,
            .Cached => info.physical.cached = value,
            .Shmem => info.physical.shared = value,
            // Physical – activity
            .Active => info.physical.active = value,
            .Inactive => info.physical.inactive = value,
            .Active_anon => info.physical.active_anon = value,
            .Inactive_anon => info.physical.inactive_anon = value,
            .Active_file => info.physical.active_file = value,
            .Inactive_file => info.physical.inactive_file = value,
            // Physical – anonymous / file-backed
            .AnonPages => info.physical.anon_pages = value,
            .Mapped => info.physical.mapped = value,
            // Physical – slab
            .Slab => info.physical.slab = value,
            .SReclaimable => info.physical.slab_reclaimable = value,
            .SUnreclaim => info.physical.slab_unreclaimable = value,
            .KReclaimable => info.physical.kernel_reclaimable = value,
            // Physical – kernel / low-level
            .KernelStack => info.physical.kernel_stack = value,
            .PageTables => info.physical.page_tables = value,
            .SecPageTables => info.physical.sec_page_tables = value,
            .Percpu => info.physical.percpu = value,
            // Physical – writeback / state
            .Dirty => info.physical.dirty = value,
            .Writeback => info.physical.writeback = value,
            .WritebackTmp => info.physical.writeback_tmp = value,
            .Unevictable => info.physical.unevictable = value,
            .Mlocked => info.physical.mlocked = value,
            // Physical – huge / special pages
            .AnonHugePages => info.physical.anon_huge_pages = value,
            .FileHugePages => info.physical.file_huge_pages = value,
            .FilePmdMapped => info.physical.file_pmd_mapped = value,
            .ShmemHugePages => info.physical.shmem_huge_pages = value,
            .ShmemPmdMapped => info.physical.shmem_pmd_mapped = value,
            .Hugetlb => info.physical.hugetlb = value,
            .Hugepagesize => info.physical.hugepages_size = value,
            // Physical – direct map
            .DirectMap4k => info.physical.direct_map_4k = value,
            .DirectMap2M => info.physical.direct_map_2m = value,
            .DirectMap1G => info.physical.direct_map_1g = value,
            // Physical – misc
            .VmallocTotal => info.physical.vmalloc_total = value,
            .VmallocUsed => info.physical.vmalloc_used = value,
            .VmallocChunk => info.physical.vmalloc_chunk = value,
            .HardwareCorrupted => info.physical.hardware_corrupted = value,
            .Bounce => info.physical.bounce = value,
            .NFS_Unstable => info.physical.nfs_unstable = value,
            .CmaTotal => info.physical.cma_total = value,
            .CmaFree => info.physical.cma_free = value,
            .Unaccepted => info.physical.unaccepted = value,
            .Balloon => info.physical.balloon = value,
            // Swap
            .SwapTotal => info.swap.total = value,
            .SwapFree => info.swap.free = value,
            .SwapCached => info.swap.cached = value,
            .Zswap => info.swap.zswap = value,
            .Zswapped => info.swap.zswapped = value,
            .CommitLimit => info.swap.commit_limit = value,
            .Committed_AS => info.swap.committed_as = value,
        }
    }

    // Fallback for older kernels without MemAvailable
    if (info.physical.available == 0 and info.physical.total != 0) info.physical.available = @min(info.physical.free + info.physical.buffers + info.physical.cached, info.physical.total);

    if (info.physical.total >= info.physical.available) info.physical.used = info.physical.total - info.physical.available;
    if (info.swap.total >= info.swap.free) info.swap.used = info.swap.total - info.swap.free;

    const total = info.physical.total + info.swap.total;
    if (total != 0) info.percentage = @intFromFloat(@as(f64, @floatFromInt(info.physical.used + info.swap.used)) / @as(f64, @floatFromInt(total)) * 100.0);

    return info;
}

// Tests

const testing = std.testing;

test "parseValue - with kB unit" {
    try testing.expectEqual(@as(u64, 12345 * KB), try parseValue("12345 kB"));
    try testing.expectEqual(@as(u64, 16384000 * KB), try parseValue("16384000 kB"));
}

test "parseValue - without unit" {
    try testing.expectEqual(@as(u64, 42), try parseValue("42"));
}

test "parseValue - with whitespace" {
    try testing.expectEqual(@as(u64, 8192 * KB), try parseValue("  8192   kB  "));
}

test "parseValue - invalid" {
    try testing.expectError(MemoryError.InvalidData, parseValue(""));
    try testing.expectError(MemoryError.InvalidData, parseValue("   "));
    try testing.expectError(error.InvalidCharacter, parseValue("abc kB"));
}

test "fetchMemoryInfo" {
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const info = fetchMemoryInfo(io) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };

    try testing.expect(info.physical.total > 0);
    try testing.expect(info.physical.total >= info.physical.available);
    try testing.expect(info.physical.total >= info.physical.used);
    try testing.expect(info.percentage <= 100);
}
