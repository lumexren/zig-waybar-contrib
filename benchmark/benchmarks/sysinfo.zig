// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 lumexren
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
const network = sysinfo.network;
const runner = @import("../runner.zig");
const reporter_mod = @import("../reporter.zig");
const Reporter = reporter_mod.Reporter;

pub const BENCHMARKS = [_][]const u8{
    "sysinfo_memory_update",
    "sysinfo_cpu_update",
    "sysinfo_cpu_cold_init",
    "sysinfo_cpu_loadavg_parse",
    "sysinfo_network_rates",
    "sysinfo_network_rates_100x",
    "sysinfo_wireless_stats_parse",
};

const SysinfoBenchContext = struct {
    io: Io,
};

fn benchMemoryUpdate(allocator: Allocator, ctx: SysinfoBenchContext) !void {
    _ = allocator;
    var memm: Memory = .init(ctx.io);
    defer memm.deinit();
    try memm.update();
}

fn benchCpuUpdateSteady(allocator: Allocator, cpu: *CPU) !void {
    _ = allocator;
    try cpu.update();
}

fn benchCpuColdInit(allocator: Allocator, ctx: SysinfoBenchContext) !void {
    var cpu: CPU = .init(ctx.io, allocator);
    defer cpu.deinit();
    try cpu.update();
}

fn benchCpuLoadAvgParse(allocator: Allocator, _: void) !void {
    _ = allocator;
    const line = "1.24 0.98 0.75 2/842 192841";
    const parsed = try CPU.parseLoadAvg(line);
    mem.doNotOptimizeAway(parsed);
}

fn benchNetworkRateCalculationSingle(allocator: Allocator, _: void) !void {
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

    const rates = NetworkStats.calculateRates(old_stats, new_stats);
    mem.doNotOptimizeAway(rates);
}

fn benchNetworkRateCalculation100x(allocator: Allocator, _: void) !void {
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

fn benchWirelessStatsParse(allocator: Allocator, _: void) !void {
    _ = allocator;
    const content =
        \\Inter-| sta-|   Quality        |   Discarded packets               | Missed | WE
        \\ face | tus | link level noise |  nwid  crypt   frag  retry   misc | beacon | 22
        \\ wlp3s0: 0000   56.  -54.  -256.        0      0      0      0      0        0
        \\
    ;
    var info = network.WifiInfo{};
    network.parseWirelessStats(content, "wlp3s0", &info);
    mem.doNotOptimizeAway(info);
}

fn shouldRun(name: []const u8, filter: ?[]const u8) bool {
    const f = filter orelse return true;
    return mem.find(u8, name, f) != null or mem.eql(u8, f, "sysinfo");
}

pub fn runBenchmarks(allocator: Allocator, io: Io, reporter: *Reporter, writer: anytype, options: runner.BenchmarkOptions, filter: ?[]const u8) !void {
    const ctx = SysinfoBenchContext{ .io = io };

    if (shouldRun("sysinfo_memory_update", filter)) {
        const r = try runner.run(allocator, "sysinfo_memory_update", options, benchMemoryUpdate, ctx);
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_cpu_update", filter)) {
        // Reused CPU instance: benchmarks real-world poll latency without cold-start baseline sleep
        var steady_cpu: CPU = .init(io, allocator);
        defer steady_cpu.deinit();
        const r = try runner.run(allocator, "sysinfo_cpu_update", options, benchCpuUpdateSteady, &steady_cpu);
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_cpu_cold_init", filter)) {
        // Cold initialization includes the 100ms baseline sleep; run fewer iterations
        const cold_opts: runner.BenchmarkOptions = .{
            .warmup_iterations = 1,
            .min_iterations = 5,
            .target_duration_ns = 500_000_000,
            .max_samples = 5,
        };
        const r = try runner.run(allocator, "sysinfo_cpu_cold_init", cold_opts, benchCpuColdInit, ctx);
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_cpu_loadavg_parse", filter)) {
        const r = try runner.run(allocator, "sysinfo_cpu_loadavg_parse", options, benchCpuLoadAvgParse, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_network_rates", filter)) {
        const r = try runner.run(allocator, "sysinfo_network_rates", options, benchNetworkRateCalculationSingle, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_network_rates_100x", filter)) {
        const r = try runner.run(allocator, "sysinfo_network_rates_100x", options, benchNetworkRateCalculation100x, {});
        try reporter.report(writer, r);
    }

    if (shouldRun("sysinfo_wireless_stats_parse", filter)) {
        const r = try runner.run(allocator, "sysinfo_wireless_stats_parse", options, benchWirelessStatsParse, {});
        try reporter.report(writer, r);
    }
}
