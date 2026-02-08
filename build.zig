const std = @import("std");
const Build = std.Build;
const SemanticVersion = std.SemanticVersion;

const Version: SemanticVersion = .{ .major = 2, .minor = 0, .patch = 0 };

const ModuleConfig = struct {
    name: []const u8,
    path: []const u8,
    link_libc: bool = false,
    link_dbus: bool = false,
    link_wireplumber: bool = false,
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
    .{ .name = "mpris", .path = "src/mpris.zig", .link_libc = true, .link_dbus = true },
    .{ .name = "battery", .path = "src/battery.zig", .link_libc = true, .link_dbus = true },
    .{ .name = "backlight", .path = "src/backlight.zig" },
    .{ .name = "bluetooth", .path = "src/bluetooth.zig", .link_libc = true, .link_dbus = true },
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

        // Link D-Bus for modules that need it (mpris, battery, bluetooth)
        if (config.link_dbus) {
            mod.linkSystemLibrary("dbus-1", .{});
        }

        // Link WirePlumber/GLib for audio module
        if (config.link_wireplumber) {
            mod.linkSystemLibrary("wireplumber-0.5", .{});
            mod.linkSystemLibrary("glib-2.0", .{});
            mod.linkSystemLibrary("gobject-2.0", .{});
        }

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
