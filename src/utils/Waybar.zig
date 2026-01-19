// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 erffy
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

/// Waybar instance manager
pub const Waybar = @This();

const std = @import("std");
const Process = @import("Process.zig");
const Io = std.Io;

io: Io,
process_handle: ?Process.Process,
config: Config,
check_counter: u32,

/// Configuration for Waybar manager behavior
pub const Config = struct {
    /// Signal number to send to waybar
    signal_number: u8,
    /// How many failed notifications before attempting to re-find waybar
    check_interval: u32 = 10,
};

/// Initialize waybar manager, searching for the waybar process
pub fn init(io: Io, config: Config) !Waybar {
    const handle = Process.findByName(io, "waybar") catch null;
    return .{
        .io = io,
        .config = config,
        .process_handle = handle,
        .check_counter = 0,
    };
}

/// Initialize without immediately searching for waybar
pub fn initLazy(io: Io, config: Config) Waybar {
    return .{
        .io = io,
        .config = config,
        .process_handle = null,
        .check_counter = 0,
    };
}

/// Send update signal to waybar
pub fn update(this: *Waybar) !void {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            // Waybar process died, invalidate handle
            this.process_handle = null;
            this.check_counter = 0;
            return;
        };

        return;
    }

    // Attempt to re-find waybar periodically
    this.check_counter += 1;
    if (this.check_counter >= this.config.check_interval) {
        this.check_counter = 0;
        if (Process.findByName(this.io, "waybar")) |h| {
            if (h) |handle| {
                this.process_handle = handle;
                // Send signal immediately after finding waybar
                try handle.sendRtSignal(this.config.signal_number);
            }

            return;
        } else |_| {
            return;
        }
    }
}

/// Force refresh waybar handle
pub fn refresh(this: *Waybar) !void {
    this.process_handle = try Process.findByName(this.io, "waybar");
    this.check_counter = 0;
}

/// Check if waybar is currently available
pub fn isAvailable(this: *const Waybar) bool {
    return this.process_handle != null;
}

/// Get current signal number
pub fn getSignalNumber(this: *const Waybar) u8 {
    return this.config.signal_number;
}

/// Update signal number at runtime
pub fn setSignalNumber(this: *Waybar, signal: u8) void {
    this.config.signal_number = signal;
}
