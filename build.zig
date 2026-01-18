// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 - 2026 erffy
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
const builtin = std.builtin;
const Build = std.Build;
const SemanticVersion = std.SemanticVersion;

/// Project version
const VERSION = SemanticVersion{ .major = 2, .minor = 0, .patch = 0 };

/// Configuration for building an executable module
const ModuleConfig = struct {
    name: []const u8,
    source_path: []const u8,
    needs_libc: bool = false,
};

/// Core modules that are always built
const core_modules = [_]ModuleConfig{
    .{ .name = "cpu", .source_path = "src/modules/cpu/root.zig" },
    .{ .name = "updates", .source_path = "src/modules/updates/root.zig" },
    .{ .name = "memory", .source_path = "src/modules/memory/root.zig" },
    .{ .name = "network", .source_path = "src/modules/network/root.zig" },
    .{ .name = "ping", .source_path = "src/modules/ping/root.zig" },
    .{ .name = "fan", .source_path = "src/modules/fan/root.zig" },
};

/// Detected or Configured System Paths
const SystemConfig = struct {
    rocm_path: []const u8,
    cuda_path: []const u8,

    // Capability flags
    has_amdsmi: bool,
    has_nvml: bool,

    fn anyGpu(this: @This()) bool {
        return this.has_amdsmi or this.has_nvml;
    }
};

/// Context passed around to build functions
const BuildContext = struct {
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: builtin.OptimizeMode,
    options_module: *Build.Module,
    core_module: *Build.Module,
    sys_config: SystemConfig,
    no_binary: bool,
};

pub fn build(b: *Build) void {
    // Standard Targets
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const no_bin = b.option(bool, "no-bin", "Skip emitting binary") orelse false;

    // Allow users to override paths: `zig build -Drocm-path=/usr/lib/rocm ...`
    const rocm_path = b.option([]const u8, "rocm-path", "Path to ROCm installation") orelse "/opt/rocm";
    const cuda_path = b.option([]const u8, "cuda-path", "Path to CUDA installation") orelse "/opt/cuda/targets/x86_64-linux";

    // We construct paths dynamically to check existence
    const amdsmi_lib = b.pathJoin(&.{ rocm_path, "lib", "libamd_smi.so" });
    const nvml_lib = b.pathJoin(&.{ cuda_path, "lib", "stubs", "libnvidia-ml.so" });

    const sys_config = SystemConfig{
        .rocm_path = rocm_path,
        .cuda_path = cuda_path,
        .has_amdsmi = fileExists(amdsmi_lib),
        .has_nvml = fileExists(nvml_lib),
    };

    // Create Modules
    const build_options = configureBuildOptions(b, sys_config);

    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ctx = BuildContext{
        .b = b,
        .target = target,
        .optimize = optimize,
        .options_module = build_options,
        .core_module = core_module,
        .sys_config = sys_config,
        .no_binary = no_bin,
    };

    // Build Core Modules
    for (core_modules) |config| {
        buildExecutable(ctx, config);
    }

    // Build GPU Module (Conditional)
    if (sys_config.anyGpu()) {
        buildGpuExecutable(ctx);
    }
}

/// Helper to check file existence using standard fs
fn fileExists(path: []const u8) bool {
    var io_threaded: Io.Threaded = .init_single_threaded;
    const io = io_threaded.io();

    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn configureBuildOptions(b: *Build, sys: SystemConfig) *Build.Module {
    const options = b.addOptions();
    options.addOption(bool, "has_amdsmi", sys.has_amdsmi);
    options.addOption(bool, "has_nvml", sys.has_nvml);
    return options.createModule();
}

fn createBaseModule(ctx: BuildContext, config: ModuleConfig) *Build.Module {
    const module = ctx.b.createModule(.{
        .root_source_file = ctx.b.path(config.source_path),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = config.needs_libc,
    });

    module.addImport("core", ctx.core_module);
    module.addImport("build_options", ctx.options_module);

    return module;
}

fn buildExecutable(ctx: BuildContext, config: ModuleConfig) void {
    const module = createBaseModule(ctx, config);

    const exe = ctx.b.addExecutable(.{
        .name = config.name,
        .root_module = module,
        .version = VERSION,
    });

    // This mapping reflects intentional trade-offs:
    //  - Debug / ReleaseSafe: fast builds, better diagnostics
    //  - ReleaseSmall: size-focused via ThinLTO
    //  - ReleaseFast: maximum cross-TU optimization via Full LTO
    exe.lto = switch (ctx.optimize) {
        .Debug, .ReleaseSafe => .none,
        .ReleaseSmall => .thin,
        .ReleaseFast => .full,
    };

    if (ctx.no_binary) {
        ctx.b.getInstallStep().dependOn(&exe.step);
    } else {
        ctx.b.installArtifact(exe);
    }

    const run_cmd = ctx.b.addRunArtifact(exe);
    if (ctx.b.args) |args| run_cmd.addArgs(args);

    const run_step = ctx.b.step(ctx.b.fmt("run-{s}", .{config.name}), ctx.b.fmt("Run the {s} module", .{config.name}));
    run_step.dependOn(&run_cmd.step);
}

fn buildGpuExecutable(ctx: BuildContext) void {
    const config = ModuleConfig{
        .name = "gpu",
        .source_path = "src/modules/gpu/root.zig",
        .needs_libc = true,
    };

    const module = createBaseModule(ctx, config);
    const sys = ctx.sys_config;

    // Configure ROCm / AMD
    if (sys.has_amdsmi) {
        // Use pathJoin for cross-platform safety (though likely Linux only)
        const lib_path = ctx.b.pathJoin(&.{ sys.rocm_path, "lib" });
        const inc_path = ctx.b.pathJoin(&.{ sys.rocm_path, "include" });

        module.addLibraryPath(.{ .cwd_relative = lib_path });
        module.addIncludePath(.{ .cwd_relative = inc_path });

        module.linkSystemLibrary("amd_smi", .{});
    }

    // Configure NVML / CUDA
    if (sys.has_nvml) {
        const lib_path = ctx.b.pathJoin(&.{ sys.cuda_path, "lib" });
        const inc_path = ctx.b.pathJoin(&.{ sys.cuda_path, "include" });

        module.addLibraryPath(.{ .cwd_relative = lib_path });
        module.addIncludePath(.{ .cwd_relative = inc_path });
        module.linkSystemLibrary("nvidia-ml", .{});
    }

    // Create Executable
    const exe = ctx.b.addExecutable(.{
        .name = config.name,
        .root_module = module,
        .version = VERSION,
    });

    if (ctx.optimize != .Debug) exe.lto = .full;

    if (ctx.no_binary) {
        ctx.b.getInstallStep().dependOn(&exe.step);
    } else {
        ctx.b.installArtifact(exe);
    }

    // Run Step for GPU
    const run_cmd = ctx.b.addRunArtifact(exe);
    if (ctx.b.args) |args| run_cmd.addArgs(args);

    const run_step = ctx.b.step("run-gpu", "Run the gpu module");
    run_step.dependOn(&run_cmd.step);
}
