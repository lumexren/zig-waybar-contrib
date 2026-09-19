// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 erenvly

const TrackingAllocator = @import("TrackingAllocator.zig");
const Result = @import("Result.zig");

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const Allocator = mem.Allocator;
const os = std.os;
const linux = os.linux;

pub const BenchmarkOptions = struct {
    warmup_iterations: u64 = 10,
    min_iterations: u64 = 50,
    target_duration_ns: u64 = 100_000_000, // 100ms
};

pub fn getMonotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn run(base_allocator: Allocator, name: []const u8, options: BenchmarkOptions, comptime func: anytype, context: anytype) !Result {
    var tracker: TrackingAllocator = .init(base_allocator);
    const alloc = tracker.allocator();

    // Warm-up phase
    for (0..options.warmup_iterations) |_| {
        try func(alloc, context);
    }
    tracker.reset();

    // Measurement phase
    var iters: u64 = 0;
    const start_time = getMonotonicNs();
    var elapsed: u64 = 0;

    while (true) {
        try func(alloc, context);
        iters += 1;

        if (iters >= options.min_iterations) {
            const now = getMonotonicNs();
            elapsed = now - start_time;
            if (elapsed >= options.target_duration_ns) break;
        }
    }

    const mean_ns = if (iters > 0) @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(iters)) else 0;
    const ops_per_sec = if (elapsed > 0) (@as(f64, @floatFromInt(iters)) * 1_000_000_000.0) / @as(f64, @floatFromInt(elapsed)) else 0;
    const allocs_per_op = if (iters > 0) @as(f64, @floatFromInt(tracker.alloc_count)) / @as(f64, @floatFromInt(iters)) else 0;

    return .{
        .name = name,
        .iterations = iters,
        .total_ns = elapsed,
        .mean_ns = mean_ns,
        .ops_per_sec = ops_per_sec,
        .allocs_per_op = allocs_per_op,
        .peak_bytes = tracker.peak_allocated,
        .leaked_bytes = tracker.leakedBytes(),
    };
}

pub fn printHeader() void {
    debug.print("\n{s:<40} {s:>10} {s:>12} {s:>14} {s:>11} {s:>10} {s:>8}\n", .{
        "Benchmark",
        "Iters",
        "Time/Op",
        "Ops/Sec",
        "Allocs/Op",
        "Peak Mem",
        "Leaks",
    });
    debug.print("----------------------------------------------------------------------------------------------------------------\n", .{});
}

pub fn printResult(result: Result) void {
    var time_buf: [32]u8 = undefined;
    var mem_buf: [32]u8 = undefined;
    var leak_buf: [32]u8 = undefined;

    const time_str = Result.formatDuration(result.mean_ns, &time_buf);
    const mem_str = Result.formatBytes(result.peak_bytes, &mem_buf);
    const leak_str = if (result.leaked_bytes == 0)
        "ok"
    else
        Result.formatBytes(result.leaked_bytes, &leak_buf);

    debug.print("{s:<40} {d:>10} {s:>12} {d:>14.0} {d:>11.1} {s:>10} {s:>8}\n", .{
        result.name,
        result.iterations,
        time_str,
        result.ops_per_sec,
        result.allocs_per_op,
        mem_str,
        leak_str,
    });
}
