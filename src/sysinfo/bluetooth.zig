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

pub const BluetoothError = error{
    ConnectionFailed,
    CallFailed,
    NoAdapter,
    InvalidResponse,
    OutOfMemory,
};

/// Bluetooth adapter information
pub const AdapterInfo = struct {
    path: []const u8,
    name: ?[]const u8 = null,
    address: ?[]const u8 = null,
    powered: bool = false,
    discoverable: bool = false,
    discovering: bool = false,

    pub fn deinit(this: *@This(), allocator: Allocator) void {
        allocator.free(this.path);
        if (this.name) |n| allocator.free(n);
        if (this.address) |a| allocator.free(a);
        this.* = undefined;
    }
};

/// Bluetooth device information
pub const DeviceInfo = struct {
    path: []const u8,
    address: ?[]const u8 = null,
    name: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    paired: bool = false,
    connected: bool = false,
    trusted: bool = false,
    blocked: bool = false,
    battery: ?u8 = null,
    icon: ?[]const u8 = null,

    pub fn deinit(this: *@This(), allocator: Allocator) void {
        allocator.free(this.path);
        if (this.address) |a| allocator.free(a);
        if (this.name) |n| allocator.free(n);
        if (this.alias) |a| allocator.free(a);
        if (this.icon) |i| allocator.free(i);
        this.* = undefined;
    }
};

const BLUEZ_SERVICE = "org.bluez";
const BLUEZ_PATH = "/";
const OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager";
const PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
const ADAPTER_IFACE = "org.bluez.Adapter1";
const DEVICE_IFACE = "org.bluez.Device1";
const BATTERY_IFACE = "org.bluez.Battery1";

/// Get all Bluetooth adapters
pub fn getAdapters(allocator: Allocator) ![]AdapterInfo {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SYSTEM, &err) orelse return BluetoothError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BluetoothError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const msg = dbus.dbus_message_new_method_call(BLUEZ_SERVICE, BLUEZ_PATH, OBJECT_MANAGER_IFACE, "GetManagedObjects") orelse return BluetoothError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse
        return BluetoothError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BluetoothError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var adapters: ArrayListUnmanaged(AdapterInfo) = .empty;
    errdefer {
        for (adapters.items) |*a| a.deinit(allocator);
        adapters.deinit(allocator);
    }

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return BluetoothError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_ARRAY) return BluetoothError.InvalidResponse;

    var obj_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &obj_iter);

    while (dbus.dbus_message_iter_get_arg_type(&obj_iter) == dbus.TYPE_DICT_ENTRY) {
        var entry_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&obj_iter, &entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_OBJECT_PATH) {
            _ = dbus.dbus_message_iter_next(&obj_iter);
            continue;
        }

        var path_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&entry_iter, @ptrCast(&path_ptr));
        const path = mem.sliceTo(path_ptr, 0);

        _ = dbus.dbus_message_iter_next(&entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_ARRAY) {
            _ = dbus.dbus_message_iter_next(&obj_iter);
            continue;
        }

        var iface_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&entry_iter, &iface_iter);

        var found_adapter = false;
        var adapter = AdapterInfo{ .path = try allocator.dupe(u8, path) };
        errdefer adapter.deinit(allocator);

        while (dbus.dbus_message_iter_get_arg_type(&iface_iter) == dbus.TYPE_DICT_ENTRY) {
            var iface_entry: dbus.MessageIter = .{};
            dbus.dbus_message_iter_recurse(&iface_iter, &iface_entry);

            if (dbus.dbus_message_iter_get_arg_type(&iface_entry) != dbus.TYPE_STRING) {
                _ = dbus.dbus_message_iter_next(&iface_iter);
                continue;
            }

            var iface_name_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&iface_entry, @ptrCast(&iface_name_ptr));
            const iface_name = mem.sliceTo(iface_name_ptr, 0);

            if (mem.eql(u8, iface_name, ADAPTER_IFACE)) {
                found_adapter = true;

                _ = dbus.dbus_message_iter_next(&iface_entry);

                if (dbus.dbus_message_iter_get_arg_type(&iface_entry) == dbus.TYPE_ARRAY) {
                    parseAdapterProperties(allocator, &iface_entry, &adapter) catch {};
                }
            }

            _ = dbus.dbus_message_iter_next(&iface_iter);
        }

        if (found_adapter) {
            try adapters.append(allocator, adapter);
        } else {
            adapter.deinit(allocator);
        }

        _ = dbus.dbus_message_iter_next(&obj_iter);
    }

    return adapters.toOwnedSlice(allocator);
}

/// Get all Bluetooth devices
pub fn getDevices(allocator: Allocator) ![]DeviceInfo {
    var err: dbus.Error = .{};
    dbus.dbus_error_init(&err);
    defer dbus.dbus_error_free(&err);

    const conn = dbus.dbus_bus_get(dbus.BUS_SYSTEM, &err) orelse return BluetoothError.ConnectionFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BluetoothError.ConnectionFailed;
    defer dbus.dbus_connection_unref(conn);

    const msg = dbus.dbus_message_new_method_call(BLUEZ_SERVICE, BLUEZ_PATH, OBJECT_MANAGER_IFACE, "GetManagedObjects") orelse return BluetoothError.CallFailed;
    defer dbus.dbus_message_unref(msg);

    const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, 5000, &err) orelse
        return BluetoothError.CallFailed;
    if (dbus.dbus_error_is_set(&err) != 0) return BluetoothError.CallFailed;
    defer dbus.dbus_message_unref(reply);

    var devices: ArrayListUnmanaged(DeviceInfo) = .empty;
    errdefer {
        for (devices.items) |*d| d.deinit(allocator);
        devices.deinit(allocator);
    }

    var iter: dbus.MessageIter = .{};
    if (dbus.dbus_message_iter_init(reply, &iter) == 0) return BluetoothError.InvalidResponse;

    if (dbus.dbus_message_iter_get_arg_type(&iter) != dbus.TYPE_ARRAY) return BluetoothError.InvalidResponse;

    var obj_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(&iter, &obj_iter);

    while (dbus.dbus_message_iter_get_arg_type(&obj_iter) == dbus.TYPE_DICT_ENTRY) {
        var entry_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&obj_iter, &entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_OBJECT_PATH) {
            _ = dbus.dbus_message_iter_next(&obj_iter);
            continue;
        }

        var path_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&entry_iter, @ptrCast(&path_ptr));
        const path = mem.sliceTo(path_ptr, 0);

        _ = dbus.dbus_message_iter_next(&entry_iter);

        if (dbus.dbus_message_iter_get_arg_type(&entry_iter) != dbus.TYPE_ARRAY) {
            _ = dbus.dbus_message_iter_next(&obj_iter);
            continue;
        }

        var iface_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&entry_iter, &iface_iter);

        var found_device = false;
        var device = DeviceInfo{ .path = try allocator.dupe(u8, path) };
        errdefer device.deinit(allocator);

        while (dbus.dbus_message_iter_get_arg_type(&iface_iter) == dbus.TYPE_DICT_ENTRY) {
            var iface_entry: dbus.MessageIter = .{};
            dbus.dbus_message_iter_recurse(&iface_iter, &iface_entry);

            if (dbus.dbus_message_iter_get_arg_type(&iface_entry) != dbus.TYPE_STRING) {
                _ = dbus.dbus_message_iter_next(&iface_iter);
                continue;
            }

            var iface_name_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&iface_entry, @ptrCast(&iface_name_ptr));
            const iface_name = mem.sliceTo(iface_name_ptr, 0);

            if (mem.eql(u8, iface_name, DEVICE_IFACE)) {
                found_device = true;
                _ = dbus.dbus_message_iter_next(&iface_entry);

                if (dbus.dbus_message_iter_get_arg_type(&iface_entry) == dbus.TYPE_ARRAY) {
                    parseDeviceProperties(allocator, &iface_entry, &device) catch {};
                }
            } else if (mem.eql(u8, iface_name, BATTERY_IFACE)) {
                _ = dbus.dbus_message_iter_next(&iface_entry);

                if (dbus.dbus_message_iter_get_arg_type(&iface_entry) == dbus.TYPE_ARRAY) {
                    parseBatteryProperties(&iface_entry, &device);
                }
            }

            _ = dbus.dbus_message_iter_next(&iface_iter);
        }

        if (found_device) {
            try devices.append(allocator, device);
        } else {
            device.deinit(allocator);
        }

        _ = dbus.dbus_message_iter_next(&obj_iter);
    }

    return devices.toOwnedSlice(allocator);
}

/// Get only connected devices
pub fn getConnectedDevices(allocator: Allocator) ![]DeviceInfo {
    var all = try getDevices(allocator);
    var count: usize = 0;
    for (all) |d| {
        if (d.connected) {
            all[count] = d;
            count += 1;
        } else {
            var mutable_d = d;
            mutable_d.deinit(allocator);
        }
    }

    return allocator.realloc(all, count);
}

fn parseAdapterProperties(allocator: Allocator, iter: *dbus.MessageIter, adapter: *AdapterInfo) !void {
    var props_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(iter, &props_iter);

    while (dbus.dbus_message_iter_get_arg_type(&props_iter) == dbus.TYPE_DICT_ENTRY) {
        var prop_entry: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&props_iter, &prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_STRING) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var prop_name_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&prop_entry, @ptrCast(&prop_name_ptr));
        const prop_name = mem.sliceTo(prop_name_ptr, 0);

        _ = dbus.dbus_message_iter_next(&prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_VARIANT) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var variant_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&prop_entry, &variant_iter);

        const val_type = dbus.dbus_message_iter_get_arg_type(&variant_iter);

        if (mem.eql(u8, prop_name, "Name") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            adapter.name = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Address") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            adapter.address = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Powered") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            adapter.powered = val != 0;
        } else if (mem.eql(u8, prop_name, "Discoverable") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            adapter.discoverable = val != 0;
        } else if (mem.eql(u8, prop_name, "Discovering") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            adapter.discovering = val != 0;
        }

        _ = dbus.dbus_message_iter_next(&props_iter);
    }
}

fn parseDeviceProperties(allocator: Allocator, iter: *dbus.MessageIter, device: *DeviceInfo) !void {
    var props_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(iter, &props_iter);

    while (dbus.dbus_message_iter_get_arg_type(&props_iter) == dbus.TYPE_DICT_ENTRY) {
        var prop_entry: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&props_iter, &prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_STRING) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var prop_name_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&prop_entry, @ptrCast(&prop_name_ptr));
        const prop_name = mem.sliceTo(prop_name_ptr, 0);

        _ = dbus.dbus_message_iter_next(&prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_VARIANT) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var variant_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&prop_entry, &variant_iter);

        const val_type = dbus.dbus_message_iter_get_arg_type(&variant_iter);

        if (mem.eql(u8, prop_name, "Address") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            device.address = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Name") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            device.name = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Alias") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            device.alias = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Icon") and val_type == dbus.TYPE_STRING) {
            var val_ptr: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val_ptr));
            device.icon = try allocator.dupe(u8, mem.sliceTo(val_ptr, 0));
        } else if (mem.eql(u8, prop_name, "Paired") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            device.paired = val != 0;
        } else if (mem.eql(u8, prop_name, "Connected") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            device.connected = val != 0;
        } else if (mem.eql(u8, prop_name, "Trusted") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            device.trusted = val != 0;
        } else if (mem.eql(u8, prop_name, "Blocked") and val_type == dbus.TYPE_BOOLEAN) {
            var val: u32 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            device.blocked = val != 0;
        }

        _ = dbus.dbus_message_iter_next(&props_iter);
    }
}

fn parseBatteryProperties(iter: *dbus.MessageIter, device: *DeviceInfo) void {
    var props_iter: dbus.MessageIter = .{};
    dbus.dbus_message_iter_recurse(iter, &props_iter);

    while (dbus.dbus_message_iter_get_arg_type(&props_iter) == dbus.TYPE_DICT_ENTRY) {
        var prop_entry: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&props_iter, &prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_STRING) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var prop_name_ptr: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&prop_entry, @ptrCast(&prop_name_ptr));
        const prop_name = mem.sliceTo(prop_name_ptr, 0);

        _ = dbus.dbus_message_iter_next(&prop_entry);

        if (dbus.dbus_message_iter_get_arg_type(&prop_entry) != dbus.TYPE_VARIANT) {
            _ = dbus.dbus_message_iter_next(&props_iter);
            continue;
        }

        var variant_iter: dbus.MessageIter = .{};
        dbus.dbus_message_iter_recurse(&prop_entry, &variant_iter);

        if (mem.eql(u8, prop_name, "Percentage") and dbus.dbus_message_iter_get_arg_type(&variant_iter) == dbus.TYPE_BYTE) {
            var val: u8 = 0;
            dbus.dbus_message_iter_get_basic(&variant_iter, @ptrCast(&val));
            device.battery = val;
        }

        _ = dbus.dbus_message_iter_next(&props_iter);
    }
}

// Tests

const testing = std.testing;

test "AdapterInfo.deinit" {
    var adapter = AdapterInfo{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0"),
        .name = try testing.allocator.dupe(u8, "hci0"),
        .address = try testing.allocator.dupe(u8, "00:11:22:33:44:55"),
    };
    adapter.deinit(testing.allocator);
}

test "DeviceInfo.deinit" {
    var device = DeviceInfo{
        .path = try testing.allocator.dupe(u8, "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"),
        .name = try testing.allocator.dupe(u8, "Test Device"),
        .address = try testing.allocator.dupe(u8, "AA:BB:CC:DD:EE:FF"),
    };
    device.deinit(testing.allocator);
}

test "getAdapters - integration" {
    const adapters = getAdapters(testing.allocator) catch |err| {
        switch (err) {
            BluetoothError.ConnectionFailed, BluetoothError.CallFailed => return,
            else => return err,
        }
    };
    defer {
        for (adapters) |*a| @constCast(a).deinit(testing.allocator);
        testing.allocator.free(adapters);
    }
}

test "getDevices - integration" {
    const devices = getDevices(testing.allocator) catch |err| {
        switch (err) {
            BluetoothError.ConnectionFailed, BluetoothError.CallFailed => return,
            else => return err,
        }
    };
    defer {
        for (devices) |*d| @constCast(d).deinit(testing.allocator);
        testing.allocator.free(devices);
    }

    // Verify all devices have paths
    for (devices) |d| {
        try testing.expect(d.path.len > 0);
    }
}
