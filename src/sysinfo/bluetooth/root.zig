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

const Bluetooth = @This();

pub const BluetoothError = @import("BluetoothError.zig").BluetoothError;
pub const AdapterInfo = @import("AdapterInfo.zig");
pub const DeviceInfo = @import("DeviceInfo.zig");

const plume = @import("plume");
const Connection = plume.Connection;
const Proxy = plume.Proxy;
const Value = plume.Value;
const GVariant = Value.GVariant;

const std = @import("std");
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;

const BLUEZ_SERVICE: [:0]const u8 = "org.bluez";
const BLUEZ_PATH: [:0]const u8 = "/";
const OBJECT_MANAGER_IFACE: [:0]const u8 = "org.freedesktop.DBus.ObjectManager";
const ADAPTER_IFACE: [:0]const u8 = "org.bluez.Adapter1";
const DEVICE_IFACE: [:0]const u8 = "org.bluez.Device1";
const BATTERY_IFACE: [:0]const u8 = "org.bluez.Battery1";

io: Io,
allocator: Allocator,
connection: *Connection,
proxy: Proxy,

pub fn init(io: Io, allocator: Allocator, connection: *Connection) Bluetooth {
    return .{
        .io = io,
        .allocator = allocator,
        .connection = connection,
        .proxy = .init(connection, BLUEZ_SERVICE, BLUEZ_PATH, OBJECT_MANAGER_IFACE),
    };
}

pub fn deinit(this: *Bluetooth) void {
    this.* = undefined;
}

/// Get all Bluetooth adapters via bluez ObjectManager
pub fn getAdapters(this: *Bluetooth) ![]AdapterInfo {
    var res = this.proxy.call("GetManagedObjects", .{}) catch return BluetoothError.ConnectionFailed;
    defer res.deinit();

    var adapters: ArrayListUnmanaged(AdapterInfo) = .empty;
    errdefer {
        for (adapters.items) |*a| a.deinit(this.allocator);
        adapters.deinit(this.allocator);
    }

    const objects = res.expectAlloc(Value.GVariant) catch return BluetoothError.InvalidResponse;
    var obj_var = objects;
    defer obj_var.deinit(this.allocator);

    if (obj_var != .dict) return BluetoothError.InvalidResponse;
    var it = obj_var.dict.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const ifaces_var = entry.value_ptr.*;
        if (ifaces_var != .dict) continue;

        var iface_it = ifaces_var.dict.iterator();
        var found = false;
        var adapter = AdapterInfo{ .path = try this.allocator.dupe(u8, path) };
        errdefer adapter.deinit(this.allocator);

        while (iface_it.next()) |iface_entry| {
            if (!mem.eql(u8, iface_entry.key_ptr.*, ADAPTER_IFACE)) continue;
            found = true;
            const props = iface_entry.value_ptr.*;
            if (props != .dict) continue;
            var prop_it = props.dict.iterator();
            while (prop_it.next()) |prop| {
                const v = prop.value_ptr.*;
                const inner = if (v == .variant) v.variant.* else v;
                if (mem.eql(u8, prop.key_ptr.*, "Name")) {
                    if (inner == .string) adapter.name = try this.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Address")) {
                    if (inner == .string) adapter.address = try this.allocator.dupe(u8, inner.string.s);
                } else if (mem.eql(u8, prop.key_ptr.*, "Powered")) {
                    if (inner == .boolean) adapter.powered = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Discoverable")) {
                    if (inner == .boolean) adapter.discoverable = inner.boolean;
                } else if (mem.eql(u8, prop.key_ptr.*, "Discovering")) {
                    if (inner == .boolean) adapter.discovering = inner.boolean;
                }
            }
        }

        if (found) {
            try adapters.append(this.allocator, adapter);
        } else {
            adapter.deinit(this.allocator);
        }
    }

    return adapters.toOwnedSlice(this.allocator);
}

/// Get all Bluetooth devices via bluez ObjectManager
pub fn getDevices(this: *Bluetooth) ![]DeviceInfo {
    var res = this.proxy.call("GetManagedObjects", .{}) catch return BluetoothError.ConnectionFailed;
    defer res.deinit();

    var devices: ArrayListUnmanaged(DeviceInfo) = .empty;
    errdefer {
        for (devices.items) |*d| d.deinit(this.allocator);
        devices.deinit(this.allocator);
    }

    const objects = res.expectAlloc(GVariant) catch return BluetoothError.InvalidResponse;
    var obj_var = objects;
    defer obj_var.deinit(this.allocator);

    if (obj_var != .dict) return BluetoothError.InvalidResponse;
    var it = obj_var.dict.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        const ifaces_var = entry.value_ptr.*;
        if (ifaces_var != .dict) continue;

        var iface_it = ifaces_var.dict.iterator();
        var found = false;
        var device = DeviceInfo{ .path = try this.allocator.dupe(u8, path) };
        errdefer device.deinit(this.allocator);

        while (iface_it.next()) |iface_entry| {
            if (mem.eql(u8, iface_entry.key_ptr.*, DEVICE_IFACE)) {
                found = true;
                const props = iface_entry.value_ptr.*;
                if (props != .dict) continue;
                var prop_it = props.dict.iterator();
                while (prop_it.next()) |prop| {
                    const v = prop.value_ptr.*;
                    const inner = if (v == .variant) v.variant.* else v;
                    if (mem.eql(u8, prop.key_ptr.*, "Address")) {
                        if (inner == .string) device.address = try this.allocator.dupe(u8, inner.string.s);
                    } else if (mem.eql(u8, prop.key_ptr.*, "Name")) {
                        if (inner == .string) device.name = try this.allocator.dupe(u8, inner.string.s);
                    } else if (mem.eql(u8, prop.key_ptr.*, "Alias")) {
                        if (inner == .string) device.alias = try this.allocator.dupe(u8, inner.string.s);
                    } else if (mem.eql(u8, prop.key_ptr.*, "Icon")) {
                        if (inner == .string) device.icon = try this.allocator.dupe(u8, inner.string.s);
                    } else if (mem.eql(u8, prop.key_ptr.*, "Paired")) {
                        if (inner == .boolean) device.paired = inner.boolean;
                    } else if (mem.eql(u8, prop.key_ptr.*, "Connected")) {
                        if (inner == .boolean) device.connected = inner.boolean;
                    } else if (mem.eql(u8, prop.key_ptr.*, "Trusted")) {
                        if (inner == .boolean) device.trusted = inner.boolean;
                    } else if (mem.eql(u8, prop.key_ptr.*, "Blocked")) {
                        if (inner == .boolean) device.blocked = inner.boolean;
                    }
                }
            } else if (mem.eql(u8, iface_entry.key_ptr.*, BATTERY_IFACE)) {
                const props = iface_entry.value_ptr.*;
                if (props != .dict) continue;
                var prop_it = props.dict.iterator();
                while (prop_it.next()) |prop| {
                    if (mem.eql(u8, prop.key_ptr.*, "Percentage")) {
                        const v = prop.value_ptr.*;
                        const inner = if (v == .variant) v.variant.* else v;
                        if (inner == .byte) device.battery = inner.byte;
                    }
                }
            }
        }

        if (found) {
            try devices.append(this.allocator, device);
        } else {
            device.deinit(this.allocator);
        }
    }

    return devices.toOwnedSlice(this.allocator);
}

/// Get only connected devices
pub fn getConnectedDevices(this: *Bluetooth) ![]DeviceInfo {
    var all = try this.getDevices();
    var count: usize = 0;
    for (all) |d| {
        if (d.connected) {
            all[count] = d;
            count += 1;
        } else {
            var mutable_d = d;
            mutable_d.deinit(this.allocator);
        }
    }
    return this.allocator.realloc(all, count);
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
