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

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const sysinfo = @import("sysinfo");
const disk = sysinfo.disk;
const runner = @import("../runner.zig");
const reporter_mod = @import("../reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const BENCHMARKS = [_][]const u8{
    "disk_stats_parse_all",
    "disk_stats_parse_target",
    "disk_io_rate_calc",
    "disk_format_bytes",
    "disk_ignored_fs_lookup",
    "disk_statvfs_root",
};

const SAMPLE_DISKSTATS =
    \\   8       0 sda 15420 310 1250200 8420 45210 1200 4502000 12500 0 10200 20920
    \\   8       1 sda1 12000 200 1000000 6000 40000 1000 4000000 10000 0 8000 16000
    \\   8       2 sda2 3420 110 250200 2420 5210 200 502000 2500 0 2200 4920
    \\ 259       0 nvme0n1 45200 0 8920100 2400 98200 0 15200300 4500 0 3500 6900
    \\ 259       1 nvme0n1p1 1000 0 100000 100 200 0 50000 50 0 150 150
    \\ 259       2 nvme0n1p2 44200 0 8820100 2300 98000 0 15150300 4450 0 3350 6750
    \\   7       0 loop0 120 0 240 10 0 0 0 0 0 10 10
    \\
;

fn benchDiskStatsParseAll(allocator: Allocator, _: void) !void {
    _ = allocator;
    const stats = disk.parseDiskStats(SAMPLE_DISKSTATS, null, 1000);
    mem.doNotOptimizeAway(stats);
}

fn benchDiskStatsParseTarget(allocator: Allocator, _: void) !void {
    _ = allocator;
    const stats = disk.parseDiskStats(SAMPLE_DISKSTATS, "/dev/nvme0n1", 1000);
    mem.doNotOptimizeAway(stats);
}

fn benchDiskIoRateCalc(allocator: Allocator, _: void) !void {
    _ = allocator;
    const old_stats: disk.DiskIOStats = .{
        .read_bytes = 10_000_000,
        .write_bytes = 5_000_000,
        .timestamp = 1000,
    };
    const new_stats: disk.DiskIOStats = .{
        .read_bytes = 15_500_000,
        .write_bytes = 8_200_000,
        .timestamp = 1002,
    };

    const rates = disk.DiskIOStats.calculateRates(old_stats, new_stats);
    mem.doNotOptimizeAway(rates);
}

fn benchDiskFormatBytes(allocator: Allocator, _: void) !void {
    _ = allocator;
    var buf: [32]u8 = undefined;
    const b1 = try disk.formatBytes(512, &buf);
    const b2 = try disk.formatBytes(2048, &buf);
    const b3 = try disk.formatBytes(5 * 1024 * 1024, &buf);
    const b4 = try disk.formatBytes(10 * 1024 * 1024 * 1024, &buf);
    mem.doNotOptimizeAway(b1);
    mem.doNotOptimizeAway(b2);
    mem.doNotOptimizeAway(b3);
    mem.doNotOptimizeAway(b4);
}

fn benchDiskIgnoredFsLookup(allocator: Allocator, _: void) !void {
    _ = allocator;
    const res1 = disk.isIgnoredFsType("tmpfs");
    const res2 = disk.isIgnoredFsType("ext4");
    const res3 = disk.isIgnoredFsType("cgroup2");
    const res4 = disk.isIgnoredFsType("btrfs");
    mem.doNotOptimizeAway(res1);
    mem.doNotOptimizeAway(res2);
    mem.doNotOptimizeAway(res3);
    mem.doNotOptimizeAway(res4);
}

fn benchDiskStatvfsRoot(allocator: Allocator, _: void) !void {
    _ = allocator;
    const info = try disk.fetchRootDiskInfo();
    mem.doNotOptimizeAway(info);
}

fn shouldRun(name: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return mem.indexOf(u8, name, f) != null or mem.eql(u8, f, "disk");
}

pub fn runBenchmarks(
    allocator: Allocator,
    reporter: *Reporter,
    writer: anytype,
    options: runner.BenchmarkOptions,
    filter: ?[]const u8,
) !void {
    if (shouldRun("disk_stats_parse_all", filter)) {
        const r = try runner.run(allocator, "disk_stats_parse_all", options, benchDiskStatsParseAll, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("disk_stats_parse_target", filter)) {
        const r = try runner.run(allocator, "disk_stats_parse_target", options, benchDiskStatsParseTarget, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("disk_io_rate_calc", filter)) {
        const r = try runner.run(allocator, "disk_io_rate_calc", options, benchDiskIoRateCalc, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("disk_format_bytes", filter)) {
        const r = try runner.run(allocator, "disk_format_bytes", options, benchDiskFormatBytes, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("disk_ignored_fs_lookup", filter)) {
        const r = try runner.run(allocator, "disk_ignored_fs_lookup", options, benchDiskIgnoredFsLookup, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("disk_statvfs_root", filter)) {
        const r = try runner.run(allocator, "disk_statvfs_root", options, benchDiskStatvfsRoot, {});
        try reporter.report(writer, r);
    }
}
