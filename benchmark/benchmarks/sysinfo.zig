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
const Io = std.Io;
const mem = std.mem;
const Allocator = mem.Allocator;

const sysinfo = @import("sysinfo");
const Memory = sysinfo.Memory;
const CPU = sysinfo.CPU;
const NetworkStats = sysinfo.network.NetworkStats;
const runner = @import("../runner.zig");

const SysinfoBenchContext = struct {
    io: Io,
};

fn benchMemoryUpdate(allocator: Allocator, ctx: SysinfoBenchContext) !void {
    _ = allocator;
    var memm = Memory.init(ctx.io);
    defer memm.deinit();
    try memm.update();
}

fn benchCpuUpdate(allocator: Allocator, ctx: SysinfoBenchContext) !void {
    var cpu = CPU.init(ctx.io, allocator);
    defer cpu.deinit();
    try cpu.update();
}

fn benchNetworkRateCalculation(allocator: Allocator, _: SysinfoBenchContext) !void {
    _ = allocator;
    const old_stats = NetworkStats{
        .rx_bytes = 10_000_000,
        .tx_bytes = 5_000_000,
        .timestamp = 1000,
    };
    const new_stats = NetworkStats{
        .rx_bytes = 12_500_000,
        .tx_bytes = 6_200_000,
        .timestamp = 1002,
    };

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const rates = NetworkStats.calculateRates(old_stats, new_stats);
        mem.doNotOptimizeAway(rates);
    }
}

pub fn runBenchmarks(allocator: Allocator, io: Io, filter: ?[]const u8) !void {
    const ctx = SysinfoBenchContext{ .io = io };
    const opts: runner.BenchmarkOptions = .{};

    if (filter == null or mem.find(u8, "sysinfo_memory_update", filter.?) != null) {
        const r1 = try runner.run(allocator, "sysinfo_memory_update", opts, benchMemoryUpdate, ctx);
        runner.printResult(r1);
    }

    if (filter == null or mem.find(u8, "sysinfo_cpu_update", filter.?) != null) {
        // CPU update touches sysfs/proc; lower iterations to keep benchmark fast
        const cpu_opts: runner.BenchmarkOptions = .{
            .warmup_iterations = 2,
            .min_iterations = 20,
            .target_duration_ns = 50_000_000,
        };
        const r2 = try runner.run(allocator, "sysinfo_cpu_update", cpu_opts, benchCpuUpdate, ctx);
        runner.printResult(r2);
    }

    if (filter == null or mem.find(u8, "sysinfo_network_rates_100x", filter.?) != null) {
        const r3 = try runner.run(allocator, "sysinfo_network_rates_100x", opts, benchNetworkRateCalculation, ctx);
        runner.printResult(r3);
    }
}
