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
const Io = std.Io;
const Dir = Io.Dir;
const Threaded = Io.Threaded;
const process = std.process;
const Build = std.Build;
const LtoMode = std.zig.LtoMode;

const Version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 0 };

const ModuleConfig = struct {
    name: []const u8,
    path: []const u8,
    libc: bool = false,
};

const modules = [_]ModuleConfig{
    .{ .name = "cpu", .path = "src/modules/cpu.zig" },
    .{ .name = "updates", .path = "src/modules/updates.zig" },
    .{ .name = "memory", .path = "src/modules/memory.zig" },
    .{ .name = "network", .path = "src/modules/network.zig" },
    .{ .name = "ping", .path = "src/modules/ping.zig" },
    .{ .name = "fan", .path = "src/modules/fan.zig" },
    .{ .name = "gpu", .path = "src/modules/gpu.zig", .libc = true },
    .{ .name = "disk", .path = "src/modules/disk.zig", .libc = true },
    .{ .name = "mpris", .path = "src/modules/mpris.zig" },
    .{ .name = "battery", .path = "src/modules/battery.zig" },
    .{ .name = "backlight", .path = "src/modules/backlight.zig" },
    .{ .name = "bluetooth", .path = "src/modules/bluetooth.zig" },
    .{ .name = "pipewire", .path = "src/modules/pipewire.zig" },
};

pub fn build(b: *Build) void {
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lto: LtoMode = switch (optimize) {
        .debug, .safe => .none,
        .small => .thin,
        .fast => .full,
    };

    const strip: bool = switch (lto) {
        .none => false,
        else => true,
    };

    const rocm_path = b.option([]const u8, "rocm-path", "Path to ROCm") orelse "/opt/rocm";
    const cuda_path = b.option([]const u8, "cuda-path", "Path to CUDA") orelse "/opt/cuda/targets/x86_64-linux";

    const has_amdsmi = fileExists(io, b.pathJoin(&.{ rocm_path, "lib", "libamd_smi.so" }));
    const has_nvml = fileExists(io, b.pathJoin(&.{ cuda_path, "lib", "stubs", "libnvidia-ml.so" }));

    const options = b.addOptions();
    options.addOption(bool, "has_amdsmi", has_amdsmi);
    options.addOption(bool, "has_nvml", has_nvml);

    const build_options = options.createModule();

    const plume_mod = b.dependency("plume", .{
        .target = target,
    }).module("plume");

    const bindings = b.addModule("bindings", .{
        .root_source_file = b.path("src/bindings/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const utils_mod = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bindings", .module = bindings }},
    });

    const sysinfo_mod = b.addModule("sysinfo", .{
        .root_source_file = b.path("src/sysinfo/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bindings", .module = bindings },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "build_options", .module = build_options },
            .{ .name = "plume", .module = plume_mod },
        },
    });

    if (has_amdsmi) linkGpu(sysinfo_mod, rocm_path, "amd_smi");
    if (has_nvml) linkGpu(sysinfo_mod, cuda_path, "nvidia-ml");

    for (modules) |cfg| {
        if (target.query.abi == .musl and cfg.libc) continue;

        const mod = b.createModule(.{
            .root_source_file = b.path(cfg.path),
            .target = target,
            .optimize = optimize,
            .link_libc = cfg.libc,
            .strip = strip,
            .imports = &.{
                .{ .name = "bindings", .module = bindings },
                .{ .name = "sysinfo", .module = sysinfo_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "build_options", .module = build_options },
                .{ .name = "plume", .module = plume_mod },
            },
        });

        const exe = b.addExecutable(.{
            .name = cfg.name,
            .root_module = mod,
            .version = Version,
        });

        exe.lto = lto;

        b.installArtifact(exe);
    }

    const test_step = b.step("test", "Run unit tests");
    const utils_tests = b.addTest(.{
        .root_module = utils_mod,
    });
    const run_utils_tests = b.addRunArtifact(utils_tests);
    test_step.dependOn(&run_utils_tests.step);

    const sysinfo_tests = b.addTest(.{
        .root_module = sysinfo_mod,
    });
    const run_sysinfo_tests = b.addRunArtifact(sysinfo_tests);
    test_step.dependOn(&run_sysinfo_tests.step);

    const bench_step = b.step("bench", "Run performance and memory benchmarks");
    const bench_filter = b.option([]const u8, "filter", "Filter benchmarks by name");

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmark/root.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "sysinfo", .module = sysinfo_mod },
            .{ .name = "bindings", .module = bindings },
            .{ .name = "build_options", .module = build_options },
            .{ .name = "plume", .module = plume_mod },
        },
    });

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });

    bench_exe.lto = .full;

    const run_bench = b.addRunArtifact(bench_exe);
    if (bench_filter) |f| {
        run_bench.addArg(f);
    }
    bench_step.dependOn(&run_bench.step);
}

fn linkGpu(mod: *Build.Module, base_path: []const u8, lib_name: []const u8) void {
    const b = mod.owner;
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ base_path, "lib" }) });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ base_path, "include" }) });
    mod.linkSystemLibrary(lib_name, .{ .needed = true });
}

fn fileExists(io: Io, path: []const u8) bool {
    Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
