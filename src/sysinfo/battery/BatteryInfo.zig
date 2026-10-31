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

const BatteryInfo = @This();

const DeviceType = @import("DeviceType.zig").DeviceType;
const BatteryState = @import("BatteryState.zig").BatteryState;

const std = @import("std");
const Allocator = std.mem.Allocator;

path: []const u8,
native_path: ?[]const u8 = null,
model: ?[]const u8 = null,
vendor: ?[]const u8 = null,
device_type: DeviceType = .battery,
state: BatteryState = .unknown,
percentage: f64 = 0,
energy: f64 = 0, // Wh
energy_full: f64 = 0, // Wh
energy_full_design: f64 = 0, // Wh
energy_rate: f64 = 0, // W
voltage: f64 = 0, // V
time_to_empty: i64 = 0, // seconds
time_to_full: i64 = 0, // seconds
is_present: bool = false,
is_rechargeable: bool = false,
health: ?u8 = null, // calculated

pub fn deinit(this: *BatteryInfo, allocator: Allocator) void {
    allocator.free(this.path);
    if (this.native_path) |p| allocator.free(p);
    if (this.model) |m| allocator.free(m);
    if (this.vendor) |v| allocator.free(v);
    this.* = undefined;
}
