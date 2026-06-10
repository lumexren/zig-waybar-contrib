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
const ArrayList = std.ArrayList;
const Io = std.Io;
const Dir = Io.Dir;
const ascii = std.ascii;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const FanInfo = struct {
    name: []const u8,
    speed: i64,
};

pub fn scanHwmonFans(io: Io, allocator: Allocator, fans: *ArrayList(FanInfo), sysfs_root: []const u8) !void {
    var hwmon_dir = try Dir.openDirAbsolute(io, sysfs_root, .{ .iterate = true });
    defer hwmon_dir.close(io);

    var it = hwmon_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "hwmon")) continue;

        var device_dir = try hwmon_dir.openDir(io, entry.name, .{ .iterate = true });
        defer device_dir.close(io);

        try scanDeviceFans(io, allocator, device_dir, fans);
    }
}

pub fn scanDeviceFans(io: Io, allocator: Allocator, device_dir: Dir, fans: *ArrayList(FanInfo)) !void {
    var it = device_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!mem.startsWith(u8, entry.name, "fan") or !mem.endsWith(u8, entry.name, "_input")) continue;

        const speed = readFanSpeed(io, device_dir, entry.name) catch continue;
        if (speed <= 0) continue;

        const name = try readFanName(io, allocator, device_dir, entry.name);
        try fans.append(allocator, .{ .name = name, .speed = speed });
    }
}

pub fn readFanSpeed(io: Io, device_dir: Dir, input_name: []const u8) !i64 {
    var file = try device_dir.openFile(io, input_name, .{});
    defer file.close(io);

    var buf: [32]u8 = undefined;
    const len = try file.readStreaming(io, &.{buf[0..]});

    const trimmed = mem.trim(u8, buf[0..len], &ascii.whitespace);
    return fmt.parseInt(i64, trimmed, 10);
}

pub fn readFanName(io: Io, allocator: Allocator, device_dir: Dir, input_name: []const u8) ![]const u8 {
    if (mem.endsWith(u8, input_name, "_input")) {
        const base = input_name[0 .. input_name.len - 6];

        var label_buf: [64]u8 = undefined;
        const label_name = fmt.bufPrint(&label_buf, "{s}_label", .{base}) catch unreachable;

        if (device_dir.openFile(io, label_name, .{})) |label_file| {
            defer label_file.close(io);

            var buf: [64]u8 = undefined;
            const len = label_file.readStreaming(io, &.{buf[0..]}) catch 0;
            if (len > 0) return allocator.dupe(u8, mem.trim(u8, buf[0..len], &ascii.whitespace));
        } else |_| {}
    }

    if (device_dir.openFile(io, "name", .{})) |name_file| {
        defer name_file.close(io);

        var buf: [64]u8 = undefined;
        const len = name_file.readStreaming(io, &.{buf[0..]}) catch 0;

        if (len > 0) {
            const dev_name = mem.trim(u8, buf[0..len], &ascii.whitespace);
            const fan_id = input_name[0 .. input_name.len - 6];
            return fmt.allocPrint(allocator, "{s} {s}", .{ dev_name, fan_id });
        }
    } else |_| {}

    return allocator.dupe(u8, input_name);
}

test "scanDeviceFans reproduction" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup: Create a fake hwmon device dir
    // We need to write files into it.
    // std.testing.tmpDir returns a struct wrapping std.fs.Dir.
    // std.fs.Dir.writeFile takes `sub_path: []const u8, data: []const u8`.
    // Wait, the error said: `expected type 'Io', found '*const [10:0]u8'`.
    // This implies `tmp.dir` is of type `Dir` which is `Io.Dir` (custom), NOT `std.fs.Dir`?
    // Let's check imports. `const Dir = Io.Dir;`.
    // BUT `std.testing.tmpDir` returns `std.testing.TmpDir`.
    // `tmp.dir` is `std.fs.Dir`.
    // The error says:
    // `lib/fan.zig:121:27: error: expected type 'Io', found '*const [10:0]u8'`
    // `try tmp.dir.writeFile("fan1_input", "2000\no");`
    // This means `tmp.dir` behaves like it expects `Io` as first arg?
    // Maybe `std` IS patched globally in this environment?
    // Or maybe I am misreading the error.
    // `note: struct declared here ... std/Io/Dir.zig`
    // It seems `std.fs.Dir` MIGHT be aliased to `std.Io.Dir` or similar?
    // OR `std.testing.tmpDir` returns something that has `writeFile` that expects `Io`.

    // Let's try passing `io` to writeFile if that's what it wants.
    // `tmp.dir` is likely `std.fs.Dir`.
    // If `std.fs.Dir` is modified to take `io`, then:
    // Error said: member function expected 2 argument(s), found 4
    // `pub fn writeFile(dir: Dir, io: Io, options: WriteFileOptions)`
    // So usage is `dir.writeFile(io, options)`.
    // options likely has fields for path and data.
    try tmp.dir.writeFile(io, .{ .sub_path = "fan1_input", .data = "2000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "fan1_label", .data = "System Fan\n" });

    // Attempt scan
    const FanList = ArrayList(FanInfo);
    var fans = FanList{};
    defer {
        for (fans.items) |*f| allocator.free(f.name);
        fans.deinit(allocator);
    }

    // We need to open tmp.dir as a Dir for scanDeviceFans
    // But scanDeviceFans takes `std.Io.Dir`.
    // Wait, `std.Io` is custom again?
    // In `lib/fan.zig`, `const Dir = Io.Dir;`
    // In `lib/build.zig`, `Threaded` comes from `std.Io`.
    // The provided `io` has methods to open dirs.
    // However, `scanDeviceFans` takes `device_dir: Dir`.
    // `std.fs.Dir` is NOT compatible with `Io.Dir` likely if it's a wrapper.
    // Let's check `lib/cpu.zig` again or assume `Io` wraps `std.fs`.
    // If I look at `lib/fan.zig`: `const Dir = Io.Dir;`.
    // `scanDeviceFans` takes `device_dir: Dir`.
    // `tmp.dir` is `std.fs.Dir`.
    // I probably need to open it via `io` wrapper.
    // `io.openDirAbsolute` exists.
    // `tmp.dir.realpath` can give me an absolute path.

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var device_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer device_dir.close(io);

    try scanDeviceFans(io, allocator, device_dir, &fans);

    // Expect 1 fan found
    try std.testing.expectEqual(@as(usize, 1), fans.items.len);
    try std.testing.expectEqualStrings("System Fan", fans.items[0].name);
    try std.testing.expectEqual(@as(i64, 2000), fans.items[0].speed);
    // Wait, I want to assert the BUG exists first, or fix it and assert it works?
    // Best practice: write test that FAILS with bug.
    // So expectation should be `1`. It will fail.
}

test "scanDeviceFans fallback" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Setup: fan2_input and name file
    try tmp.dir.writeFile(io, .{ .sub_path = "fan2_input", .data = "1500\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "name", .data = "k10temp\n" });

    // Attempt scan
    const FanList = ArrayList(FanInfo);
    var fans = FanList{};
    defer {
        for (fans.items) |*f| allocator.free(f.name);
        fans.deinit(allocator);
    }

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    var device_dir = try Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer device_dir.close(io);

    try scanDeviceFans(io, allocator, device_dir, &fans);

    // Expect 1 fan: "k10temp fan2"
    try std.testing.expectEqualStrings("k10temp fan2", fans.items[0].name);
    try std.testing.expectEqual(@as(i64, 1500), fans.items[0].speed);
}

test "scanHwmonFans" {
    const allocator = std.testing.allocator;
    const Threaded = std.Io.Threaded;
    var threaded: Threaded = .init_single_threaded;
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create structure:
    // tmp/hwmon0/fan1_input
    // tmp/hwmon0/fan1_label
    // tmp/hwmon1/fan1_input (no label)
    // tmp/other/ (should be ignored)

    // We need subdirectories.
    // Try passing io to createDir (makeDir not present)
    try tmp.dir.createDir(io, "hwmon0", .default_dir);
    try tmp.dir.createDir(io, "hwmon1", .default_dir);
    try tmp.dir.createDir(io, "other", .default_dir);

    // hwmon0 files
    // Note: writeFile in standard zig (latest) usually takes sub_path.
    // But we saw explicit `io` requirement in previous steps.
    // However, `tmp.dir` is `std.fs.Dir`. `makeDir` is standard.
    // The previous tests used `tmp.dir.writeFile(io, ...)` because of `std` patch presumably.
    // So we continue that pattern.

    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon0/fan1_input", .data = "1000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon0/fan1_label", .data = "CPU Fan\n" });

    // hwmon1 files (no label, so name should be hwmon1 fan1)
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon1/fan1_input", .data = "2000\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hwmon1/name", .data = "box\n" }); // Driver name

    // Attempt scan
    const FanList = ArrayList(FanInfo);
    var fans = FanList{};
    defer {
        for (fans.items) |*f| allocator.free(f.name);
        fans.deinit(allocator);
    }

    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);
    const path = buf[0..len];

    try scanHwmonFans(io, allocator, &fans, path);

    // Expect 2 fans
    // Order depends on directory iteration order (hash map logic usually in fs), so we can't guarantee order.
    try std.testing.expectEqual(@as(usize, 2), fans.items.len);

    var found_cpu = false;
    var found_box = false;

    for (fans.items) |f| {
        if (mem.eql(u8, f.name, "CPU Fan")) {
            try std.testing.expectEqual(@as(i64, 1000), f.speed);
            found_cpu = true;
        } else if (mem.eql(u8, f.name, "box fan1")) {
            try std.testing.expectEqual(@as(i64, 2000), f.speed);
            found_box = true;
        } else {
            std.debug.print("Found unexpected fan: {s}\n", .{f.name});
        }
    }

    try std.testing.expect(found_cpu);
    try std.testing.expect(found_box);
}
