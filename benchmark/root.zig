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
const fmt = std.fmt;
const Io = std.Io;
const File = Io.File;

const runner = @import("runner.zig");
const reporter_mod = @import("reporter.zig");
const Reporter = reporter_mod.Reporter;
const OutputFormat = reporter_mod.OutputFormat;

const bench_json = @import("benchmarks/json.zig");
const bench_replacer = @import("benchmarks/replacer.zig");
const bench_sysinfo = @import("benchmarks/sysinfo.zig");
const bench_disk = @import("benchmarks/disk.zig");
const bench_config = @import("benchmarks/config.zig");

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\Usage: zig build bench [-- [OPTIONS] [FILTER]]
        \\
        \\Options:
        \\  -f, --filter <str>      Filter benchmarks by name or category
        \\      --format <fmt>      Output format: table (default), verbose, markdown, json, csv
        \\  -v, --verbose           Detailed statistical breakdown per benchmark
        \\      --markdown, --md    Output results as GitHub-flavored Markdown table
        \\      --json              Output results in structured JSON format
        \\      --csv               Output results in CSV format
        \\  -d, --duration <ms>     Target duration per benchmark in ms (default: 100)
        \\  -w, --warmup <n>        Warmup iterations count (default: 10)
        \\  -m, --min-iters <n>     Minimum iteration count (default: 50)
        \\  -s, --samples <n>       Maximum sample count (default: 100)
        \\  -l, --list              List all available benchmarks and exit
        \\      --no-color          Disable ANSI color escapes
        \\      --fail-on-leak      Exit with error if any benchmark leaks memory
        \\  -h, --help              Show this help message and exit
        \\
        \\Suites:
        \\  json        JSON serialization and string formatting
        \\  replacer    Template replacer and unit conversions
        \\  sysinfo     CPU, memory, and network telemetry collectors
        \\  disk        Disk stats parsing and I/O calculations
        \\  config      ZON configuration deserialization
        \\
    , .{});
}

fn printBenchmarkList(writer: anytype) !void {
    try writer.print("Available benchmark suites:\n\n", .{});

    const suites = [_]struct {
        name: []const u8,
        benches: []const []const u8,
    }{
        .{ .name = "json", .benches = &bench_json.BENCHMARKS },
        .{ .name = "replacer", .benches = &bench_replacer.BENCHMARKS },
        .{ .name = "sysinfo", .benches = &bench_sysinfo.BENCHMARKS },
        .{ .name = "disk", .benches = &bench_disk.BENCHMARKS },
        .{ .name = "config", .benches = &bench_config.BENCHMARKS },
    };

    for (suites) |suite| {
        try writer.print("  [{s}]\n", .{suite.name});
        for (suite.benches) |b| try writer.print("    - {s}\n", .{b});
        try writer.print("\n", .{});
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    var filter: ?[]const u8 = null;
    var format: OutputFormat = .table;
    var no_color: bool = false;
    var fail_on_leak: bool = false;
    var target_duration_ms: u64 = 100;
    var warmup_iterations: u64 = 10;
    var min_iterations: u64 = 50;
    var max_samples: usize = 100;

    const args = init.minimal.args.vector;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = mem.span(args[i]);

        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            try printUsage(stdout);
            try stdout.flush();
            return;
        } else if (mem.eql(u8, arg, "-l") or mem.eql(u8, arg, "--list")) {
            try printBenchmarkList(stdout);
            try stdout.flush();
            return;
        } else if (mem.eql(u8, arg, "-v") or mem.eql(u8, arg, "--verbose")) {
            format = .verbose;
        } else if (mem.eql(u8, arg, "--markdown") or mem.eql(u8, arg, "--md")) {
            format = .markdown;
        } else if (mem.eql(u8, arg, "--json")) {
            format = .json;
        } else if (mem.eql(u8, arg, "--csv")) {
            format = .csv;
        } else if (mem.eql(u8, arg, "--no-color")) {
            no_color = true;
        } else if (mem.eql(u8, arg, "--fail-on-leak")) {
            fail_on_leak = true;
        } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i < args.len) filter = mem.span(args[i]);
        } else if (mem.startsWith(u8, arg, "--filter=")) {
            filter = arg["--filter=".len..];
        } else if (mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i < args.len) {
                const val = mem.span(args[i]);
                if (OutputFormat.fromString(val)) |fmt_val| format = fmt_val;
            }
        } else if (mem.startsWith(u8, arg, "--format=")) {
            if (OutputFormat.fromString(arg["--format=".len..])) |fmt_val| format = fmt_val;
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--duration")) {
            i += 1;
            if (i < args.len) target_duration_ms = fmt.parseInt(u64, mem.span(args[i]), 10) catch target_duration_ms;
        } else if (mem.startsWith(u8, arg, "--duration=")) {
            target_duration_ms = fmt.parseInt(u64, arg["--duration=".len..], 10) catch target_duration_ms;
        } else if (mem.eql(u8, arg, "-w") or mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i < args.len) warmup_iterations = fmt.parseInt(u64, mem.span(args[i]), 10) catch warmup_iterations;
        } else if (mem.startsWith(u8, arg, "--warmup=")) {
            warmup_iterations = fmt.parseInt(u64, arg["--warmup=".len..], 10) catch warmup_iterations;
        } else if (mem.eql(u8, arg, "-m") or mem.eql(u8, arg, "--min-iters")) {
            i += 1;
            if (i < args.len) min_iterations = fmt.parseInt(u64, mem.span(args[i]), 10) catch min_iterations;
        } else if (mem.startsWith(u8, arg, "--min-iters=")) {
            min_iterations = fmt.parseInt(u64, arg["--min-iters=".len..], 10) catch min_iterations;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--samples")) {
            i += 1;
            if (i < args.len) max_samples = fmt.parseInt(usize, mem.span(args[i]), 10) catch max_samples;
        } else if (mem.startsWith(u8, arg, "--samples=")) {
            max_samples = fmt.parseInt(usize, arg["--samples=".len..], 10) catch max_samples;
        } else if (!mem.startsWith(u8, arg, "-")) {
            if (filter == null) filter = arg;
        }
    }

    const is_tty = File.stdout().isTty(io) catch false;
    const use_color = is_tty and !no_color;

    var reporter: Reporter = .init(format, use_color);
    const options: runner.BenchmarkOptions = .{
        .warmup_iterations = warmup_iterations,
        .min_iterations = min_iterations,
        .target_duration_ns = target_duration_ms * 1_000_000,
        .max_samples = max_samples,
    };

    if (filter) |f| {
        if (format == .table or format == .verbose) try stdout.print("Filter: \"{s}\"\n", .{f});
    }

    try reporter.printHeader(stdout);

    try bench_json.runBenchmarks(gpa, &reporter, stdout, options, filter);
    try bench_replacer.runBenchmarks(gpa, &reporter, stdout, options, filter);
    try bench_sysinfo.runBenchmarks(gpa, io, &reporter, stdout, options, filter);
    try bench_disk.runBenchmarks(gpa, &reporter, stdout, options, filter);
    try bench_config.runBenchmarks(gpa, &reporter, stdout, options, filter);

    try reporter.printFooter(stdout);
    try stdout.flush();

    if (fail_on_leak and reporter.leaks_count > 0) return error.BenchmarkMemoryLeakDetected;
}

test {
    _ = @import("TrackingAllocator.zig");
    _ = @import("Result.zig");
    _ = @import("runner.zig");
    _ = @import("reporter.zig");
}
