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
// along with this program. If not, see <https://gnu.org/licenses/>.

const std = @import("std");
const Build = std.Build;
const SemanticVersion = std.SemanticVersion;

const Version: SemanticVersion = .{ .major = 3, .minor = 0, .patch = 0 };

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
    .{ .name = "backlight", .path = "src/backlight.zig", .link_libc = true, .link_dbus = true },
    .{ .name = "bluetooth", .path = "src/bluetooth.zig", .link_libc = true, .link_dbus = true },
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const zigsysinfo = b.dependency("zig_sysinfo", .{});
    const zigwaybarutils = b.dependency("zig_waybar_utils", .{});

    const base_imports: []const Build.Module.Import = &.{
        .{ .name = "sysinfo", .module = zigsysinfo.module("zig_sysinfo") },
        .{ .name = "utils", .module = zigwaybarutils.module("zig_waybar_utils") },
    };

    for (modules) |config| {
        if (target.result.abi == .musl and config.link_libc) continue;

        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path(config.path),
            .link_libc = config.link_libc,
            .imports = base_imports,
        });

        if (config.link_dbus) mod.linkSystemLibrary("dbus-1", .{});

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
