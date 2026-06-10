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

const dbus = @import("bindings").dbus;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const BatteryError = error{
    ConnectionFailed,
    CallFailed,
    NotFound,
    InvalidResponse,
    OutOfMemory,
};

/// UPower battery state
pub const BatteryState = enum(u32) {
    unknown = 0,
    charging = 1,
    discharging = 2,
    empty = 3,
    fully_charged = 4,
    pending_charge = 5,
    pending_discharge = 6,

    pub fn toString(this: @This()) [:0]const u8 {
        return switch (this) {
            .charging => "Charging",
            .discharging => "Discharging",
            .empty => "Empty",
            .fully_charged => "Full",
            .pending_charge => "Pending charge",
            .pending_discharge => "Pending discharge",
            .unknown => "Unknown",
        };
    }
};

/// UPower device type
pub const DeviceType = enum(u32) {
    unknown = 0,
    line_power = 1,
    battery = 2,
    ups = 3,
    monitor = 4,
    mouse = 5,
    keyboard = 6,
    pda = 7,
    phone = 8,
    media_player = 9,
    tablet = 10,
    computer = 11,
    gaming_input = 12,
    pen = 13,
    touchpad = 14,
    modem = 15,
    network = 16,
    headset = 17,
    speakers = 18,
    headphones = 19,
    video = 20,
    other_audio = 21,
    remote_control = 22,
    printer = 23,
    scanner = 24,
    camera = 25,
    wearable = 26,
    toy = 27,
    bluetooth_generic = 28,
    _,
};

/// Battery information from UPower
pub const BatteryInfo = struct {
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

    pub fn deinit(this: *@This(), allocator: Allocator) void {
        allocator.free(this.path);
        if (this.native_path) |p| allocator.free(p);
        if (this.model) |m| allocator.free(m);
        if (this.vendor) |v| allocator.free(v);
        this.* = undefined;
    }
};

const UPOWER_SERVICE: [*:0]const u8 = "org.freedesktop.UPower";
const UPOWER_PATH: [*:0]const u8 = "/org/freedesktop/UPower";
const UPOWER_IFACE: [*:0]const u8 = "org.freedesktop.UPower";
const DEVICE_IFACE: [*:0]const u8 = "org.freedesktop.UPower.Device";
const PROPERTIES_IFACE: [*:0]const u8 = "org.freedesktop.DBus.Properties";

/// Get all batteries from UPower
pub fn getBatteries(allocator: Allocator) ![]BatteryInfo {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SYSTEM, &err) orelse return BatteryError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BatteryError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const msg = dbus.dbus_message_new_method_call(UPOWER_SERVICE, UPOWER_PATH, UPOWER_IFACE, "EnumerateDevices") orelse return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse
        return BatteryError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var batteries: ArrayListUnmanaged(BatteryInfo) = .empty;
    errdefer {
        for (batteries.items) |*b| b.deinit(allocator);
        batteries.deinit(allocator);
    }

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return BatteryError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_ARRAY) return BatteryError.InvalidResponse;

    var arr_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &arr_iter);

    while (dbus.dbus_message_iter_get_arg_type(&arr_iter) == dbus.TYPE_OBJECT_PATH) {
        var path_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&arr_iter, @ptrCast(&path_ptr));
        const path = mem.sliceTo(path_ptr, 0);

        if (getDeviceInfo(allocator, conn, path)) |info| {
            if (info.device_type == .battery) {
                try batteries.append(allocator, info);
            } else {
                info.deinit(allocator);
            }
        } else |_| {}

        _ = dbus.dbus_message_iter_next(&arr_iter);
    }

    return batteries.toOwnedSlice(allocator);
}

/// Get the display device (primary battery)
pub fn getDisplayDevice(allocator: Allocator) !BatteryInfo {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SYSTEM, &err) orelse return BatteryError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BatteryError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const msg = dbus.dbus_message_new_method_call(UPOWER_SERVICE, UPOWER_PATH, UPOWER_IFACE, "GetDisplayDevice") orelse return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse
        return BatteryError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return BatteryError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_OBJECT_PATH) return BatteryError.InvalidResponse;

    var path_ptr: [*:0]const u8 = undefined;
    dbus.dbus_message_iter_get_basic(&iter, @ptrCast(&path_ptr));
    const path = mem.sliceTo(path_ptr, 0);

    return getDeviceInfo(allocator, conn, path);
}

fn getDeviceInfo(allocator: Allocator, conn: *dbus.Connection, path: []const u8) !BatteryInfo {
    var info = BatteryInfo{
        .path = try allocator.dupe(u8, path),
    };
    errdefer info.deinit(allocator);

    var path_buf: [257]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return BatteryError.InvalidResponse;

    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const msg = dbus.dbus_message_new_method_call(UPOWER_SERVICE, path_z, PROPERTIES_IFACE, "GetAll") orelse return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    var args_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_init_append(msg, &args_iter);
    _ = dbus.dbus_message_iter_append_basic(&args_iter, dbus.TYPE_STRING, @ptrCast(&DEVICE_IFACE));

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse
        return BatteryError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BatteryError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return BatteryError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_ARRAY) return BatteryError.InvalidResponse;

    var props_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &props_iter);

    while (dbus.dbus_message_iter_get_arg_type(&props_iter) == 'e') { // DICT_ENTRY
        var entry_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&props_iter, &entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_STRING) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var key_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&entry_iter, @ptrCast(&key_ptr));
        const key = mem.sliceTo(key_ptr, 0);

        _ = dbus.dbus_message_iter_next(&entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_VARIANT) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var variant_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&entry_iter, &variant_iter);

        const val_type = dbus.dbus_message_iter_get_arg_type(&variant_iter);

        if (mem.eql(u8, key, "Type") and val_type == dbus.TYPE_UINT32) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.device_type = @enumFromInt(val);
        } else if (mem.eql(u8, key, "State") and val_type == dbus.TYPE_UINT32) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.state = @enumFromInt(@min(val, 6));
        } else if (mem.eql(u8, key, "Percentage") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.percentage = val;
        } else if (mem.eql(u8, key, "Energy") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.energy = val;
        } else if (mem.eql(u8, key, "EnergyFull") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.energy_full = val;
        } else if (mem.eql(u8, key, "EnergyFullDesign") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.energy_full_design = val;
        } else if (mem.eql(u8, key, "EnergyRate") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.energy_rate = val;
        } else if (mem.eql(u8, key, "Voltage") and val_type == dbus.TYPE_DOUBLE) {
            var val: f64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.voltage = val;
        } else if (mem.eql(u8, key, "TimeToEmpty") and val_type == dbus.TYPE_INT64) {
            var val: i64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.time_to_empty = val;
        } else if (mem.eql(u8, key, "TimeToFull") and val_type == dbus.TYPE_INT64) {
            var val: i64 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.time_to_full = val;
        } else if (mem.eql(u8, key, "IsPresent") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.is_present = val != 0;
        } else if (mem.eql(u8, key, "IsRechargeable") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            info.is_rechargeable = val != 0;
        } else if (mem.eql(u8, key, "NativePath") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            info.native_path = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, key, "Model") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            const model = mem.sliceTo(val_ptr, 0);
            if (model.len > 0) info.model = try allocator.dupe(u8, model);
        } else if (mem.eql(u8, key, "Vendor") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            const vendor = mem.sliceTo(val_ptr, 0);
            if (vendor.len > 0) info.vendor = try allocator.dupe(u8, vendor);
        }

        _ = dbus.dbus_message_iter_next(&props_iter);
    }

    if (info.energy_full > 0 and info.energy_full_design > 0) {
        const health_pct = info.energy_full / info.energy_full_design * 100;
        info.health = @intFromFloat(@min(health_pct, 100));
    }

    return info;
}

// Tests

const testing = std.testing;

test "BatteryState.toString" {
    try testing.expectEqualStrings("Charging", BatteryState.charging.toString());
    try testing.expectEqualStrings("Discharging", BatteryState.discharging.toString());
    try testing.expectEqualStrings("Full", BatteryState.fully_charged.toString());
}

test "BatteryInfo.deinit" {
    var info = BatteryInfo{
        .path = try testing.allocator.dupe(u8, "/org/freedesktop/UPower/devices/battery_BAT0"),
        .model = try testing.allocator.dupe(u8, "Test Battery"),
    };
    info.deinit(testing.allocator);
}

test "getBatteries - integration" {
    const batteries = getBatteries(testing.allocator) catch |err| {
        switch (err) {
            BatteryError.ConnectionFailed, BatteryError.CallFailed => return,
            else => return err,
        }
    };
    defer {
        for (batteries) |*b| @constCast(b).deinit(testing.allocator);
        testing.allocator.free(batteries);
    }

    for (batteries) |b| {
        try testing.expect(b.path.len > 0);
        try testing.expect(b.percentage >= 0 and b.percentage <= 100);
    }
}
