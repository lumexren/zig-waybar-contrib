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

const TrackingAllocator = @import("TrackingAllocator.zig");
const Result = @import("Result.zig");

const std = @import("std");
const mem = std.mem;
const math = std.math;
const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;
const sort = std.sort;
const os = std.os;
const linux = os.linux;

pub const BenchmarkOptions = struct {
    warmup_iterations: u64 = 10,
    min_iterations: u64 = 50,
    target_duration_ns: u64 = 100_000_000, // 100ms
    max_samples: usize = 100,
    batch_size: ?u64 = null,
};

pub fn getMonotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn run(base_allocator: Allocator, name: []const u8, options: BenchmarkOptions, comptime func: anytype, context: anytype) !Result {
    var tracker: TrackingAllocator = .init(base_allocator);
    const alloc = tracker.allocator();

    const warmup_iters = @max(options.warmup_iterations, 3);
    const warmup_start = getMonotonicNs();
    for (0..warmup_iters) |_| try func(alloc, context);
    const warmup_elapsed = getMonotonicNs() - warmup_start;
    tracker.reset();

    const est_single_ns: f64 = if (warmup_iters > 0 and warmup_elapsed > 0)
        @as(f64, @floatFromInt(warmup_elapsed)) / @as(f64, @floatFromInt(warmup_iters))
    else
        1000.0;

    const batch_size: u64 = if (options.batch_size) |b|
        @max(b, 1)
    else blk: {
        if (est_single_ns < 10_000.0) {
            const target_sample_ns = @as(f64, @floatFromInt(options.target_duration_ns)) / @as(f64, @floatFromInt(options.max_samples));
            const desired = target_sample_ns / est_single_ns;
            const b = @as(u64, @intFromFloat(@max(10.0, desired)));
            break :blk @max(b, 1);
        } else {
            break :blk 1;
        }
    };

    var samples: ArrayList(f64) = .empty;
    defer samples.deinit(base_allocator);

    var total_iters: u64 = 0;
    var total_ns: u64 = 0;
    const bench_start = getMonotonicNs();

    while (true) {
        const sample_start = getMonotonicNs();
        for (0..batch_size) |_| try func(alloc, context);

        const sample_end = getMonotonicNs();
        const dt = sample_end - sample_start;

        const sample_single_ns = @as(f64, @floatFromInt(dt)) / @as(f64, @floatFromInt(batch_size));
        try samples.append(base_allocator, sample_single_ns);

        total_iters += batch_size;
        total_ns += dt;

        const current_elapsed = sample_end - bench_start;

        if (total_iters >= options.min_iterations and samples.items.len >= 5) {
            if (current_elapsed >= options.target_duration_ns) break;
            if (samples.items.len >= options.max_samples) break;
        }

        if (current_elapsed >= options.target_duration_ns * 4) break;
    }

    if (samples.items.len == 0) return error.NoSamplesCollected;

    mem.sort(f64, samples.items, {}, sort.asc(f64));

    const sample_count = samples.items.len;
    const min_ns = samples.items[0];
    const max_ns = samples.items[sample_count - 1];
    const median_ns = samples.items[sample_count / 2];

    const p95_idx = @min(sample_count - 1, (sample_count * 95) / 100);
    const p95_ns = samples.items[p95_idx];

    const p99_idx = @min(sample_count - 1, (sample_count * 99) / 100);
    const p99_ns = samples.items[p99_idx];

    var sum_ns: f64 = 0.0;
    for (samples.items) |s| sum_ns += s;

    const mean_ns = sum_ns / @as(f64, @floatFromInt(sample_count));

    var variance_sum: f64 = 0.0;
    for (samples.items) |s| {
        const diff = s - mean_ns;
        variance_sum += diff * diff;
    }

    const variance = variance_sum / @as(f64, @floatFromInt(sample_count));
    const stddev_ns = @sqrt(variance);

    const ops_per_sec = if (total_ns > 0)
        (@as(f64, @floatFromInt(total_iters)) * 1_000_000_000.0) / @as(f64, @floatFromInt(total_ns))
    else
        0.0;

    return .{
        .name = name,
        .iterations = total_iters,
        .sample_count = sample_count,
        .total_ns = total_ns,
        .min_ns = min_ns,
        .median_ns = median_ns,
        .mean_ns = mean_ns,
        .p95_ns = p95_ns,
        .p99_ns = p99_ns,
        .max_ns = max_ns,
        .stddev_ns = stddev_ns,
        .ops_per_sec = ops_per_sec,
        .allocs_per_op = tracker.allocsPerOp(total_iters),
        .frees_per_op = tracker.freesPerOp(total_iters),
        .reallocs_per_op = tracker.reallocsPerOp(total_iters),
        .bytes_per_op = tracker.bytesPerOp(total_iters),
        .peak_bytes = tracker.peak_allocated,
        .leaked_bytes = tracker.leakedBytes(),
    };
}

test "runner basic execution" {
    const testing = std.testing;
    const Dummy = struct {
        fn noop(allocator: Allocator, _: void) !void {
            const buf = try allocator.alloc(u8, 64);
            defer allocator.free(buf);
            mem.doNotOptimizeAway(buf);
        }
    };

    const res = try run(testing.allocator, "dummy_noop", .{
        .warmup_iterations = 2,
        .min_iterations = 10,
        .target_duration_ns = 1_000_000,
        .max_samples = 5,
    }, Dummy.noop, {});

    try testing.expectEqualStrings("dummy_noop", res.name);
    try testing.expect(res.iterations >= 10);
    try testing.expect(res.min_ns > 0.0);
    try testing.expect(!res.hasLeak());
    try testing.expectEqual(@as(usize, 0), res.leaked_bytes);
}
