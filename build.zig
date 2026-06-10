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
const Dir = Io.Dir;
const Threaded = Io.Threaded;
const Build = std.Build;

const Version: std.SemanticVersion = .{ .major = 1, .minor = 0, .patch = 0 };

const ModuleConfig = struct {
    name: []const u8,
    path: []const u8,
    dbus: bool = false,
    libc: bool = false,
};

const modules = [_]ModuleConfig{
    .{ .name = "cpu", .path = "src/cpu.zig" },
    .{ .name = "updates", .path = "src/updates.zig" },
    .{ .name = "memory", .path = "src/memory.zig" },
    .{ .name = "network", .path = "src/network.zig" },
    .{ .name = "ping", .path = "src/ping.zig" },
    .{ .name = "fan", .path = "src/fan.zig" },
    .{ .name = "gpu", .path = "src/gpu.zig", .libc = true },
    .{ .name = "disk", .path = "src/disk.zig", .libc = true },
    .{ .name = "mpris", .path = "src/mpris.zig", .libc = true, .dbus = true },
    .{ .name = "battery", .path = "src/battery.zig", .libc = true, .dbus = true },
    .{ .name = "backlight", .path = "src/backlight.zig" },
    .{ .name = "bluetooth", .path = "src/bluetooth.zig", .libc = true, .dbus = true },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const rocm_path = b.option([]const u8, "rocm-path", "Path to ROCm") orelse "/opt/rocm";
    const cuda_path = b.option([]const u8, "cuda-path", "Path to CUDA") orelse "/opt/cuda/targets/x86_64-linux";

    const has_amdsmi = fileExists(b.pathJoin(&.{ rocm_path, "lib", "libamd_smi.so" }));
    const has_nvml = fileExists(b.pathJoin(&.{ cuda_path, "lib", "stubs", "libnvidia-ml.so" }));
    const has_dbus = pkgConfigExists("dbus-1");

    const options = b.addOptions();
    options.addOption(bool, "has_amdsmi", has_amdsmi);
    options.addOption(bool, "has_nvml", has_nvml);
    options.addOption(bool, "has_dbus", has_dbus);

    const build_options = options.createModule();

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
        .imports = &.{
            .{ .name = "bindings", .module = bindings },
            .{ .name = "utils", .module = utils_mod },
            .{ .name = "build_options", .module = build_options },
        },
    });

    if (has_dbus) sysinfo_mod.linkSystemLibrary("dbus-1", .{});
    if (has_amdsmi) linkGpu(sysinfo_mod, rocm_path, "amd_smi");
    if (has_nvml) linkGpu(sysinfo_mod, cuda_path, "nvidia-ml");

    for (modules) |cfg| {
        if (target.query.abi == .musl and cfg.libc) continue;

        const mod = b.createModule(.{
            .root_source_file = b.path(cfg.path),
            .target = target,
            .optimize = optimize,
            .link_libc = cfg.libc,
            .link_libcpp = cfg.libc,
            .imports = &.{
                .{ .name = "bindings", .module = bindings },
                .{ .name = "sysinfo", .module = sysinfo_mod },
                .{ .name = "utils", .module = utils_mod },
                .{ .name = "build_options", .module = build_options },
            },
        });

        if (cfg.dbus) mod.linkSystemLibrary("dbus-1", .{ .needed = true });

        const exe = b.addExecutable(.{ .name = cfg.name, .root_module = mod, .version = Version });
        exe.lto = if (optimize == .ReleaseSmall) .thin else if (optimize == .ReleaseFast) .full else .none;
        b.installArtifact(exe);
    }
}

fn linkGpu(mod: *Build.Module, base_path: []const u8, lib_name: []const u8) void {
    const b = mod.owner;
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ base_path, "lib" }) });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ base_path, "include" }) });
    mod.linkSystemLibrary(lib_name, .{ .needed = true });
}

fn fileExists(path: []const u8) bool {
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();
    Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn pkgConfigExists(pkg: []const u8) bool {
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();
    var child = std.process.spawn(io, .{
        .argv = &.{ "pkg-config", "--exists", pkg },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term == .exited and term.exited == 0;
}
