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

const Result = @import("Result.zig");

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fmt = std.fmt;
const heap = std.heap;
const page_allocator = heap.page_allocator;

pub const OutputFormat = enum {
    table,
    verbose,
    markdown,
    json,
    csv,

    pub fn fromString(str: []const u8) ?OutputFormat {
        if (mem.eql(u8, str, "table")) return .table;
        if (mem.eql(u8, str, "verbose")) return .verbose;
        if (mem.eql(u8, str, "markdown") or mem.eql(u8, str, "md")) return .markdown;
        if (mem.eql(u8, str, "json")) return .json;
        if (mem.eql(u8, str, "csv")) return .csv;
        return null;
    }
};

const line_separator: [136]u8 = @splat('-');

pub const Reporter = struct {
    format: OutputFormat = .table,
    use_color: bool = true,
    results_count: usize = 0,
    leaks_count: usize = 0,
    total_time_ns: u64 = 0,
    json_first: bool = true,

    pub fn init(format: OutputFormat, use_color: bool) Reporter {
        return .{
            .format = format,
            .use_color = use_color and (format == .table or format == .verbose),
        };
    }

    pub fn printHeader(this: *Reporter, writer: anytype) !void {
        switch (this.format) {
            .table => {
                if (this.use_color) {
                    try writer.print("\n\x1b[1m{s:<36} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>13} {s:>10} {s:>10} {s:>9} {s:>7}\x1b[0m\n", .{
                        "Benchmark",
                        "Iters",
                        "Min",
                        "Median",
                        "Mean",
                        "P95",
                        "Ops/Sec",
                        "Allocs/Op",
                        "Bytes/Op",
                        "Peak Mem",
                        "Leaks",
                    });
                } else {
                    try writer.print("\n{s:<36} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10} {s:>13} {s:>10} {s:>10} {s:>9} {s:>7}\n", .{
                        "Benchmark",
                        "Iters",
                        "Min",
                        "Median",
                        "Mean",
                        "P95",
                        "Ops/Sec",
                        "Allocs/Op",
                        "Bytes/Op",
                        "Peak Mem",
                        "Leaks",
                    });
                }
                try writer.print("{s}\n", .{line_separator});
            },
            .verbose => {
                if (this.use_color) {
                    try writer.print("\n\x1b[1m=== Performance & Memory Benchmark Suite ===\x1b[0m\n\n", .{});
                } else {
                    try writer.print("\n=== Performance & Memory Benchmark Suite ===\n\n", .{});
                }
            },
            .markdown => {
                try writer.print("| Benchmark | Iters | Min | Median | Mean | P95 | Ops/Sec | Allocs/Op | Bytes/Op | Peak Mem | Leaks |\n", .{});
                try writer.print("|:----------|------:|----:|-------:|-----:|----:|--------:|----------:|---------:|---------:|:------|\n", .{});
            },
            .json => {
                try writer.print("{{\n  \"benchmarks\": [\n", .{});
            },
            .csv => {
                try writer.print("Benchmark,Iterations,Samples,Min_ns,Median_ns,Mean_ns,P95_ns,P99_ns,Max_ns,StdDev_ns,Ops_Per_Sec,Allocs_Per_Op,Frees_Per_Op,Bytes_Per_Op,Peak_Bytes,Leaked_Bytes\n", .{});
            },
        }
    }

    pub fn report(this: *Reporter, writer: anytype, result: Result) !void {
        this.results_count += 1;
        this.total_time_ns += result.total_ns;
        if (result.hasLeak()) this.leaks_count += 1;

        var min_buf: [32]u8 = undefined;
        var med_buf: [32]u8 = undefined;
        var mean_buf: [32]u8 = undefined;
        var p95_buf: [32]u8 = undefined;
        var p99_buf: [32]u8 = undefined;
        var max_buf: [32]u8 = undefined;
        var sd_buf: [32]u8 = undefined;
        var mem_buf: [32]u8 = undefined;
        var bpo_buf: [32]u8 = undefined;
        var leak_buf: [32]u8 = undefined;

        const min_s = Result.formatDuration(result.min_ns, &min_buf);
        const med_s = Result.formatDuration(result.median_ns, &med_buf);
        const mean_s = Result.formatDuration(result.mean_ns, &mean_buf);
        const p95_s = Result.formatDuration(result.p95_ns, &p95_buf);
        const mem_s = Result.formatBytes(result.peak_bytes, &mem_buf);
        const bpo_s = Result.formatFloatBytes(result.bytes_per_op, &bpo_buf);

        switch (this.format) {
            .table => {
                if (this.use_color) {
                    const leak_s = if (result.leaked_bytes == 0)
                        "\x1b[32mok\x1b[0m"
                    else
                        try fmt.allocPrint(page_allocator, "\x1b[31;1m{s}\x1b[0m", .{Result.formatBytes(result.leaked_bytes, &leak_buf)});
                    defer if (result.leaked_bytes != 0) page_allocator.free(leak_s);

                    try writer.print("{s:<36} {d:>9} {s:>10} {s:>10} {s:>10} {s:>10} \x1b[36m{d:>13.0}\x1b[0m {d:>10.1} {s:>10} {s:>9} {s:>16}\n", .{
                        result.name,
                        result.iterations,
                        min_s,
                        med_s,
                        mean_s,
                        p95_s,
                        result.ops_per_sec,
                        result.allocs_per_op,
                        bpo_s,
                        mem_s,
                        leak_s,
                    });
                } else {
                    const leak_s = if (result.leaked_bytes == 0) "ok" else Result.formatBytes(result.leaked_bytes, &leak_buf);
                    try writer.print("{s:<36} {d:>9} {s:>10} {s:>10} {s:>10} {s:>10} {d:>13.0} {d:>10.1} {s:>10} {s:>9} {s:>7}\n", .{
                        result.name,
                        result.iterations,
                        min_s,
                        med_s,
                        mean_s,
                        p95_s,
                        result.ops_per_sec,
                        result.allocs_per_op,
                        bpo_s,
                        mem_s,
                        leak_s,
                    });
                }
            },
            .verbose => {
                const max_s = Result.formatDuration(result.max_ns, &max_buf);
                const p99_s = Result.formatDuration(result.p99_ns, &p99_buf);
                const sd_s = Result.formatDuration(result.stddev_ns, &sd_buf);
                const pct = result.stddevPercent();

                if (this.use_color) {
                    try writer.print("\x1b[1;34m▶ {s}\x1b[0m\n", .{result.name});
                    try writer.print("  \x1b[2mIterations:\x1b[0m  {d} ({d} samples, {s} total)\n", .{
                        result.iterations,
                        result.sample_count,
                        Result.formatDuration(@as(f64, @floatFromInt(result.total_ns)), &leak_buf),
                    });
                    try writer.print("  \x1b[1mLatency:\x1b[0m\n", .{});
                    try writer.print("    Min:          {s}\n", .{min_s});
                    try writer.print("    Median (p50): \x1b[32m{s}\x1b[0m\n", .{med_s});
                    try writer.print("    Mean:         {s} (± {s} / {d:.1}%)\n", .{ mean_s, sd_s, pct });
                    try writer.print("    p95:          {s}\n", .{p95_s});
                    try writer.print("    p99:          {s}\n", .{p99_s});
                    try writer.print("    Max:          {s}\n", .{max_s});
                    try writer.print("  \x1b[1mThroughput:\x1b[0m   \x1b[36m{d:.0} ops/sec\x1b[0m\n", .{result.ops_per_sec});
                    try writer.print("  \x1b[1mMemory:\x1b[0m\n", .{});
                    try writer.print("    Operations:   {d:.2} allocs/op | {d:.2} frees/op | {d:.2} reallocs/op\n", .{
                        result.allocs_per_op,
                        result.frees_per_op,
                        result.reallocs_per_op,
                    });
                    try writer.print("    Alloc Bytes:  {s}/op\n", .{bpo_s});
                    try writer.print("    Peak Usage:   {s}\n", .{mem_s});
                    if (result.hasLeak()) {
                        try writer.print("    Leak Status:  \x1b[31;1mFAIL ({d} bytes leaked)\x1b[0m\n\n", .{result.leaked_bytes});
                    } else {
                        try writer.print("    Leak Status:  \x1b[32mPASS (0 bytes)\x1b[0m\n\n", .{});
                    }
                } else {
                    try writer.print("▶ {s}\n", .{result.name});
                    try writer.print("  Iterations:  {d} ({d} samples, {s} total)\n", .{
                        result.iterations,
                        result.sample_count,
                        Result.formatDuration(@as(f64, @floatFromInt(result.total_ns)), &leak_buf),
                    });
                    try writer.print("  Latency:\n", .{});
                    try writer.print("    Min:          {s}\n", .{min_s});
                    try writer.print("    Median (p50): {s}\n", .{med_s});
                    try writer.print("    Mean:         {s} (± {s} / {d:.1}%)\n", .{ mean_s, sd_s, pct });
                    try writer.print("    p95:          {s}\n", .{p95_s});
                    try writer.print("    p99:          {s}\n", .{p99_s});
                    try writer.print("    Max:          {s}\n", .{max_s});
                    try writer.print("  Throughput:   {d:.0} ops/sec\n", .{result.ops_per_sec});
                    try writer.print("  Memory:\n", .{});
                    try writer.print("    Operations:   {d:.2} allocs/op | {d:.2} frees/op | {d:.2} reallocs/op\n", .{
                        result.allocs_per_op,
                        result.frees_per_op,
                        result.reallocs_per_op,
                    });
                    try writer.print("    Alloc Bytes:  {s}/op\n", .{bpo_s});
                    try writer.print("    Peak Usage:   {s}\n", .{mem_s});
                    if (result.hasLeak()) {
                        try writer.print("    Leak Status:  FAIL ({d} bytes leaked)\n\n", .{result.leaked_bytes});
                    } else {
                        try writer.print("    Leak Status:  PASS (0 bytes)\n\n", .{});
                    }
                }
            },
            .markdown => {
                const leak_s = if (result.leaked_bytes == 0) "ok" else Result.formatBytes(result.leaked_bytes, &leak_buf);
                try writer.print("| {s} | {d} | {s} | {s} | {s} | {s} | {d:.0} | {d:.1} | {s} | {s} | {s} |\n", .{
                    result.name,
                    result.iterations,
                    min_s,
                    med_s,
                    mean_s,
                    p95_s,
                    result.ops_per_sec,
                    result.allocs_per_op,
                    bpo_s,
                    mem_s,
                    leak_s,
                });
            },
            .json => {
                if (!this.json_first) {
                    try writer.print(",\n", .{});
                }
                this.json_first = false;
                try writer.print(
                    \\    {{
                    \\      "name": "{s}",
                    \\      "iterations": {d},
                    \\      "samples": {d},
                    \\      "total_ns": {d},
                    \\      "time_ns": {{
                    \\        "min": {d:.2},
                    \\        "median": {d:.2},
                    \\        "mean": {d:.2},
                    \\        "p95": {d:.2},
                    \\        "p99": {d:.2},
                    \\        "max": {d:.2},
                    \\        "stddev": {d:.2}
                    \\      }},
                    \\      "ops_per_sec": {d:.2},
                    \\      "memory": {{
                    \\        "allocs_per_op": {d:.2},
                    \\        "frees_per_op": {d:.2},
                    \\        "reallocs_per_op": {d:.2},
                    \\        "bytes_per_op": {d:.2},
                    \\        "peak_bytes": {d},
                    \\        "leaked_bytes": {d}
                    \\      }}
                    \\    }}
                , .{
                    result.name,
                    result.iterations,
                    result.sample_count,
                    result.total_ns,
                    result.min_ns,
                    result.median_ns,
                    result.mean_ns,
                    result.p95_ns,
                    result.p99_ns,
                    result.max_ns,
                    result.stddev_ns,
                    result.ops_per_sec,
                    result.allocs_per_op,
                    result.frees_per_op,
                    result.reallocs_per_op,
                    result.bytes_per_op,
                    result.peak_bytes,
                    result.leaked_bytes,
                });
            },
            .csv => {
                try writer.print("{s},{d},{d},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d:.2},{d},{d}\n", .{
                    result.name,
                    result.iterations,
                    result.sample_count,
                    result.min_ns,
                    result.median_ns,
                    result.mean_ns,
                    result.p95_ns,
                    result.p99_ns,
                    result.max_ns,
                    result.stddev_ns,
                    result.ops_per_sec,
                    result.allocs_per_op,
                    result.frees_per_op,
                    result.bytes_per_op,
                    result.peak_bytes,
                    result.leaked_bytes,
                });
            },
        }
    }

    pub fn printFooter(this: *Reporter, writer: anytype) !void {
        var duration_buf: [32]u8 = undefined;
        const total_duration = Result.formatDuration(@as(f64, @floatFromInt(this.total_time_ns)), &duration_buf);

        switch (this.format) {
            .table => {
                try writer.print("{s}\n", .{line_separator});
                if (this.use_color) {
                    if (this.leaks_count == 0) {
                        try writer.print("\x1b[32;1m✓ All {d} benchmarks completed in {s} with 0 memory leaks.\x1b[0m\n\n", .{
                            this.results_count,
                            total_duration,
                        });
                    } else {
                        try writer.print("\x1b[31;1m✗ {d} of {d} benchmarks leaked memory! Total time: {s}\x1b[0m\n\n", .{
                            this.leaks_count,
                            this.results_count,
                            total_duration,
                        });
                    }
                } else {
                    if (this.leaks_count == 0) {
                        try writer.print("All {d} benchmarks completed in {s} with 0 memory leaks.\n\n", .{
                            this.results_count,
                            total_duration,
                        });
                    } else {
                        try writer.print("WARNING: {d} of {d} benchmarks leaked memory! Total time: {s}\n\n", .{
                            this.leaks_count,
                            this.results_count,
                            total_duration,
                        });
                    }
                }
            },
            .verbose => {
                if (this.use_color) {
                    try writer.print("\x1b[1m=== Benchmark Summary ===\x1b[0m\n", .{});
                    try writer.print("  Total benchmarks: {d}\n", .{this.results_count});
                    try writer.print("  Total duration:   {s}\n", .{total_duration});
                    if (this.leaks_count == 0) {
                        try writer.print("  Memory audit:     \x1b[32;1mPASS (0 leaks detected)\x1b[0m\n\n", .{});
                    } else {
                        try writer.print("  Memory audit:     \x1b[31;1mFAIL ({d} benchmarks leaked memory)\x1b[0m\n\n", .{this.leaks_count});
                    }
                } else {
                    try writer.print("=== Benchmark Summary ===\n", .{});
                    try writer.print("  Total benchmarks: {d}\n", .{this.results_count});
                    try writer.print("  Total duration:   {s}\n", .{total_duration});
                    if (this.leaks_count == 0) {
                        try writer.print("  Memory audit:     PASS (0 leaks detected)\n\n", .{});
                    } else {
                        try writer.print("  Memory audit:     FAIL ({d} benchmarks leaked memory)\n\n", .{this.leaks_count});
                    }
                }
            },
            .markdown => {
                try writer.print("\n*Ran {d} benchmarks in {s}. Leaks detected: {d}.*\n", .{
                    this.results_count,
                    total_duration,
                    this.leaks_count,
                });
            },
            .json => {
                const total_ms = @as(f64, @floatFromInt(this.total_time_ns)) / 1_000_000.0;
                try writer.print(
                    \\
                    \\  ],
                    \\  "summary": {{
                    \\    "total_benchmarks": {d},
                    \\    "total_duration_ms": {d:.2},
                    \\    "leaks_detected": {d}
                    \\  }}
                    \\}}
                    \\
                , .{
                    this.results_count,
                    total_ms,
                    this.leaks_count,
                });
            },
            .csv => {},
        }
    }
};

test "OutputFormat fromString" {
    const testing = std.testing;
    try testing.expectEqual(OutputFormat.table, OutputFormat.fromString("table").?);
    try testing.expectEqual(OutputFormat.verbose, OutputFormat.fromString("verbose").?);
    try testing.expectEqual(OutputFormat.markdown, OutputFormat.fromString("markdown").?);
    try testing.expectEqual(OutputFormat.markdown, OutputFormat.fromString("md").?);
    try testing.expectEqual(OutputFormat.json, OutputFormat.fromString("json").?);
    try testing.expectEqual(OutputFormat.csv, OutputFormat.fromString("csv").?);
    try testing.expect(OutputFormat.fromString("invalid") == null);
}
