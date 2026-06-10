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

pub const Connection = opaque {};
pub const Message = opaque {};
pub const MessageIter = extern struct {
    dummy1: ?*anyopaque = null,
    dummy2: ?*anyopaque = null,
    dummy3: u32 = 0,
    dummy4: c_int = 0,
    dummy5: c_int = 0,
    dummy6: c_int = 0,
    dummy7: c_int = 0,
    dummy8: c_int = 0,
    dummy9: c_int = 0,
    dummy10: c_int = 0,
    dummy11: c_int = 0,
    pad1: c_int = 0,
    pad2: ?*anyopaque = null,
    pad3: ?*anyopaque = null,
};

pub const Error = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    dummy_bits: u32 = 1,
    padding1: ?*anyopaque = null,
};

pub const BUS_SESSION: c_int = 0;
pub const BUS_SYSTEM: c_int = 1;
pub const BUS_STARTER: c_int = 2;
pub const TYPE_ARRAY: c_int = 'a';
pub const TYPE_STRING: c_int = 's';
pub const TYPE_VARIANT: c_int = 'v';
pub const TYPE_BOOLEAN: c_int = 'b';
pub const TYPE_DOUBLE: c_int = 'd';
pub const TYPE_DICT_ENTRY: c_int = 'e';
pub const TYPE_UINT32: c_int = 'u';
pub const TYPE_INT64: c_int = 'x';
pub const TYPE_BYTE: c_int = 'y';
pub const TYPE_OBJECT_PATH: c_int = 'o';

pub const FilterFunc = *const fn(conn: *Connection, msg: *Message, userdata: ?*anyopaque) callconv(.C) c_int;

pub extern "dbus-1" fn dbus_bus_get(bus_type: c_int, err: *Error) ?*Connection;
pub extern "dbus-1" fn dbus_connection_unref(conn: *Connection) void;
pub extern "dbus-1" fn dbus_error_init(err: *Error) void;
pub extern "dbus-1" fn dbus_error_free(err: *Error) void;
pub extern "dbus-1" fn dbus_error_is_set(err: *const Error) c_int;
pub extern "dbus-1" fn dbus_message_new_method_call(dest: [*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8) ?*Message;
pub extern "dbus-1" fn dbus_message_unref(msg: *Message) void;
pub extern "dbus-1" fn dbus_connection_send_with_reply_and_block(conn: *Connection, msg: *Message, timeout_ms: c_int, err: *Error) ?*Message;
pub extern "dbus-1" fn dbus_message_iter_init(msg: *Message, iter: *MessageIter) c_int;
pub extern "dbus-1" fn dbus_message_iter_init_append(msg: *Message, iter: *MessageIter) void;
pub extern "dbus-1" fn dbus_message_iter_get_arg_type(iter: *MessageIter) c_int;
pub extern "dbus-1" fn dbus_message_iter_recurse(iter: *MessageIter, sub: *MessageIter) void;
pub extern "dbus-1" fn dbus_message_iter_next(iter: *MessageIter) c_int;
pub extern "dbus-1" fn dbus_message_iter_get_basic(iter: *MessageIter, value: *anyopaque) void;
pub extern "dbus-1" fn dbus_message_iter_append_basic(iter: *MessageIter, arg_type: c_int, value: *const anyopaque) c_int;
pub extern "dbus-1" fn dbus_message_iter_open_container(iter: *MessageIter, container_type: c_int, sig: ?[*:0]const u8, sub: *MessageIter) c_int;
pub extern "dbus-1" fn dbus_message_iter_close_container(iter: *MessageIter, sub: *MessageIter) c_int;
pub extern "dbus-1" fn dbus_connection_add_filter(conn: *Connection, filter: FilterFunc, userdata: ?*anyopaque, freefunc: ?*const fn(?*anyopaque) callconv(.C) void) c_int;
pub extern "dbus-1" fn dbus_connection_remove_filter(conn: *Connection, filter: FilterFunc, userdata: ?*anyopaque) void;