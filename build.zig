const std = @import("std");
const Build = std.Build;
const SemanticVersion = std.SemanticVersion;

const Version: SemanticVersion = .{ .major = 2, .minor = 0, .patch = 0 };

const ModuleConfig = struct {
    name: []const u8,
    path: []const u8,
    link_libc: bool = false,
};

const modules = [_]ModuleConfig{
    .{ .name = "cpu", .path = "src/cpu.zig" },
    .{ .name = "updates", .path = "src/updates.zig" },
    .{ .name = "memory", .path = "src/memory.zig" },
    .{ .name = "network", .path = "src/network.zig" },
    .{ .name = "ping", .path = "src/ping.zig" },
    .{ .name = "fan", .path = "src/fan.zig" },
    .{ .name = "gpu", .path = "src/gpu.zig", .link_libc = true },
    .{ .name = "disk", .path = "src/disk.zig", .link_libc = true },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const zigsysinfo = b.dependency("zig_sysinfo", .{});

    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (modules) |config| {
        if (target.result.abi == .musl and config.link_libc) continue;

        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(config.path),
            .link_libc = config.link_libc,
            .imports = &.{
                .{
                    .name = "utils",
                    .module = utils,
                },
                .{
                    .name = "sysinfo",
                    .module = zigsysinfo.module("zig_sysinfo"),
                },
            },
        });

        const exe = b.addExecutable(.{
            .name = config.name,
            .root_module = mod,
            .version = Version,
        });

        // This mapping reflects intentional trade-offs:
        //  - Debug / ReleaseSafe: fast builds, better diagnostics
        //  - ReleaseSmall: size-focused via ThinLTO
        //  - ReleaseFast: maximum cross-TU optimization via Full LTO
        exe.lto = switch (optimize) {
            .Debug, .ReleaseSafe => .none,
            .ReleaseSmall => .thin,
            .ReleaseFast => .full,
        };

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| run_cmd.addArgs(args);

        const run_step = b.step(b.fmt("run-{s}", .{config.name}), b.fmt("Run the {s} module", .{config.name}));
        run_step.dependOn(&run_cmd.step);
    }
}
