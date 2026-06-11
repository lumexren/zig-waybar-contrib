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

/// Stateful tracker for Memory allocation metrics.
const Memory = @This();

const std = @import("std");
const StaticStringMap = std.StaticStringMap;
const mem = std.mem;
const fmt = std.fmt;
const Io = std.Io;
const Dir = Io.Dir;

const KB: u64 = 1024;
const MEMINFO_PATH = "/proc/meminfo";
const MEMINFO_BUFFER_SIZE: usize = 16384;

pub const MemoryError = error{
    InvalidData,
};

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
    MemTotal,
    MemFree,
    MemAvailable,
    Buffers,
    Cached,
    Shmem,
    Active,
    Inactive,
    Active_anon,
    Inactive_anon,
    Active_file,
    Inactive_file,
    AnonPages,
    Mapped,
    Slab,
    SReclaimable,
    SUnreclaim,
    KReclaimable,
    KernelStack,
    PageTables,
    SecPageTables,
    Percpu,
    Dirty,
    Writeback,
    WritebackTmp,
    Unevictable,
    Mlocked,
    AnonHugePages,
    FileHugePages,
    FilePmdMapped,
    ShmemHugePages,
    ShmemPmdMapped,
    Hugetlb,
    Hugepagesize,
    DirectMap4k,
    DirectMap2M,
    DirectMap1G,
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
    SwapTotal,
    SwapFree,
    SwapCached,
    Zswap,
    Zswapped,
    CommitLimit,
    Committed_AS,
};

const field_map: StaticStringMap(Field) = .initComptime(.{
    .{ "MemTotal", .MemTotal },                   .{ "MemFree", .MemFree },
    .{ "MemAvailable", .MemAvailable },           .{ "Buffers", .Buffers },
    .{ "Cached", .Cached },                       .{ "Shmem", .Shmem },
    .{ "Active", .Active },                       .{ "Inactive", .Inactive },
    .{ "Active(anon)", .Active_anon },            .{ "Inactive(anon)", .Inactive_anon },
    .{ "Active(file)", .Active_file },            .{ "Inactive(file)", .Inactive_file },
    .{ "AnonPages", .AnonPages },                 .{ "Mapped", .Mapped },
    .{ "Slab", .Slab },                           .{ "SReclaimable", .SReclaimable },
    .{ "SUnreclaim", .SUnreclaim },               .{ "KReclaimable", .KReclaimable },
    .{ "KernelStack", .KernelStack },             .{ "PageTables", .PageTables },
    .{ "SecPageTables", .SecPageTables },         .{ "Percpu", .Percpu },
    .{ "Dirty", .Dirty },                         .{ "Writeback", .Writeback },
    .{ "WritebackTmp", .WritebackTmp },           .{ "Unevictable", .Unevictable },
    .{ "Mlocked", .Mlocked },                     .{ "AnonHugePages", .AnonHugePages },
    .{ "FileHugePages", .FileHugePages },         .{ "FilePmdMapped", .FilePmdMapped },
    .{ "ShmemHugePages", .ShmemHugePages },       .{ "ShmemPmdMapped", .ShmemPmdMapped },
    .{ "Hugetlb", .Hugetlb },                     .{ "Hugepagesize", .Hugepagesize },
    .{ "DirectMap4k", .DirectMap4k },             .{ "DirectMap2M", .DirectMap2M },
    .{ "DirectMap1G", .DirectMap1G },             .{ "VmallocTotal", .VmallocTotal },
    .{ "VmallocUsed", .VmallocUsed },             .{ "VmallocChunk", .VmallocChunk },
    .{ "HardwareCorrupted", .HardwareCorrupted }, .{ "Bounce", .Bounce },
    .{ "NFS_Unstable", .NFS_Unstable },           .{ "CmaTotal", .CmaTotal },
    .{ "CmaFree", .CmaFree },                     .{ "Unaccepted", .Unaccepted },
    .{ "Balloon", .Balloon },                     .{ "SwapTotal", .SwapTotal },
    .{ "SwapFree", .SwapFree },                   .{ "SwapCached", .SwapCached },
    .{ "Zswap", .Zswap },                         .{ "Zswapped", .Zswapped },
    .{ "CommitLimit", .CommitLimit },             .{ "Committed_AS", .Committed_AS },
});

io: Io,
percentage: u64 = 0,
physical: PhysicalMemoryInfo = .{},
swap: SwapMemoryInfo = .{},

pub fn init(io: Io) Memory {
    return .{ .io = io };
}

pub fn deinit(this: *Memory) void {
    _ = this;
}

/// Fetches and refreshes memory metrics.
pub fn update(this: *Memory) !void {
    this.percentage = 0;
    this.physical = .{};
    this.swap = .{};

    var buffer: [MEMINFO_BUFFER_SIZE]u8 = undefined;

    var file = try Dir.openFileAbsolute(this.io, MEMINFO_PATH, .{ .mode = .read_only });
    defer file.close(this.io);

    var reader = file.reader(this.io, &.{});
    const n = try reader.interface.readSliceShort(&buffer);

    var lines = mem.splitScalar(u8, buffer[0..n], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const colon = mem.findScalar(u8, line, ':') orelse continue;
        const field = field_map.get(line[0..colon]) orelse continue;
        const value = try parseValue(mem.trimStart(u8, line[colon + 1 ..], " \t"));

        switch (field) {
            .MemTotal => this.physical.total = value,
            .MemFree => this.physical.free = value,
            .MemAvailable => this.physical.available = value,
            .Buffers => this.physical.buffers = value,
            .Cached => this.physical.cached = value,
            .Shmem => this.physical.shared = value,
            .Active => this.physical.active = value,
            .Inactive => this.physical.inactive = value,
            .Active_anon => this.physical.active_anon = value,
            .Inactive_anon => this.physical.inactive_anon = value,
            .Active_file => this.physical.active_file = value,
            .Inactive_file => this.physical.inactive_file = value,
            .AnonPages => this.physical.anon_pages = value,
            .Mapped => this.physical.mapped = value,
            .Slab => this.physical.slab = value,
            .SReclaimable => this.physical.slab_reclaimable = value,
            .SUnreclaim => this.physical.slab_unreclaimable = value,
            .KReclaimable => this.physical.kernel_reclaimable = value,
            .KernelStack => this.physical.kernel_stack = value,
            .PageTables => this.physical.page_tables = value,
            .SecPageTables => this.physical.sec_page_tables = value,
            .Percpu => this.physical.percpu = value,
            .Dirty => this.physical.dirty = value,
            .Writeback => this.physical.writeback = value,
            .WritebackTmp => this.physical.writeback_tmp = value,
            .Unevictable => this.physical.unevictable = value,
            .Mlocked => this.physical.mlocked = value,
            .AnonHugePages => this.physical.anon_huge_pages = value,
            .FileHugePages => this.physical.file_huge_pages = value,
            .FilePmdMapped => this.physical.file_pmd_mapped = value,
            .ShmemHugePages => this.physical.shmem_huge_pages = value,
            .ShmemPmdMapped => this.physical.shmem_pmd_mapped = value,
            .Hugetlb => this.physical.hugetlb = value,
            .Hugepagesize => this.physical.hugepages_size = value,
            .DirectMap4k => this.physical.direct_map_4k = value,
            .DirectMap2M => this.physical.direct_map_2m = value,
            .DirectMap1G => this.physical.direct_map_1g = value,
            .VmallocTotal => this.physical.vmalloc_total = value,
            .VmallocUsed => this.physical.vmalloc_used = value,
            .VmallocChunk => this.physical.vmalloc_chunk = value,
            .HardwareCorrupted => this.physical.hardware_corrupted = value,
            .Bounce => this.physical.bounce = value,
            .NFS_Unstable => this.physical.nfs_unstable = value,
            .CmaTotal => this.physical.cma_total = value,
            .CmaFree => this.physical.cma_free = value,
            .Unaccepted => this.physical.unaccepted = value,
            .Balloon => this.physical.balloon = value,
            .SwapTotal => this.swap.total = value,
            .SwapFree => this.swap.free = value,
            .SwapCached => this.swap.cached = value,
            .Zswap => this.swap.zswap = value,
            .Zswapped => this.swap.zswapped = value,
            .CommitLimit => this.swap.commit_limit = value,
            .Committed_AS => this.swap.committed_as = value,
        }
    }

    // Fallback logic for older Linux kernels lacking MemAvailable
    if (this.physical.available == 0 and this.physical.total != 0) {
        this.physical.available = @min(this.physical.free + this.physical.buffers + this.physical.cached, this.physical.total);
    }

    if (this.physical.total >= this.physical.available) {
        this.physical.used = this.physical.total - this.physical.available;
    }

    if (this.swap.total >= this.swap.free) {
        this.swap.used = this.swap.total - this.swap.free;
    }

    const grand_total = this.physical.total + this.swap.total;
    if (grand_total != 0) {
        this.percentage = @intFromFloat(@as(f64, @floatFromInt(this.physical.used + this.swap.used)) / @as(f64, @floatFromInt(grand_total)) * 100.0);
    }
}

/// Helper to parse raw entries (e.g., "12345 kB" -> byte representations).
inline fn parseValue(s: []const u8) !u64 {
    var it = mem.tokenizeAny(u8, s, " \t");
    const num = it.next() orelse return MemoryError.InvalidData;
    const value = try fmt.parseUnsigned(u64, num, 10);

    return if (it.next()) |u| if (mem.eql(u8, u, "kB")) value * KB else value else value;
}
