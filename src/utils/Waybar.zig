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

/// Waybar Instance Manager
///
/// Manages communication with the Waybar status bar through real-time signals.
/// Automatically handles waybar process discovery and reconnection.
///
/// Usage:
/// ```zig
/// var waybar: Waybar = try .init(io, .{ .signal_number = 10 });
///
/// // In your update loop:
/// try waybar.updateOrRefresh(); // Sends SIGRTMIN+10 to waybar
/// ```
///
/// Signal Configuration:
/// ```json
/// "custom/mymodule": {
///     "exec": "my-program",
///     "return-type": "json",
///     "signal": 10
/// }
/// ```
const Waybar = @This();

const std = @import("std");
const Process = @import("Process.zig");
const assert = std.debug.assert;
const Io = std.Io;
const os = std.os;
const linux = os.linux;

io: Io,
process_handle: ?Process.Process,
config: Config,
check_counter: u32,

pub const WaybarError = error{
    /// The configured signal number is outside the valid RT signal range
    InvalidSignalNumber,
    /// Waybar process is not running or cannot be found
    WaybarNotFound,
    /// Failed to send signal to waybar process
    SignalFailed,
};

/// Configuration for Waybar manager behavior
pub const Config = struct {
    /// Real-time signal offset (SIGRTMIN + offset). Must be 1-31.
    signal_number: u8,
    /// How many failed update attempts before re-searching for waybar process.
    /// Lower values = more responsive but higher overhead.
    check_interval: u32 = 10,

    /// Validate config values are within acceptable ranges
    pub fn validate(this: @This()) WaybarError!void {
        if (!isValidSignal(this.signal_number)) return WaybarError.InvalidSignalNumber;
    }
};

/// Check if a signal number is valid for real-time signaling
pub fn isValidSignal(signal_number: u8) bool {
    if (signal_number < 1) return false;
    return ((linux.sigrtmin() + signal_number) <= linux.sigrtmax());
}

/// Initialize waybar manager, immediately searching for the waybar process.
///
/// Returns an error if the signal number is invalid.
/// Does NOT error if waybar is not running - use `isAvailable()` to check.
pub fn init(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();

    const handle = Process.findByName(io, "waybar") catch null;
    return .{
        .io = io,
        .config = config,
        .process_handle = handle,
        .check_counter = 0,
    };
}

/// Initialize without searching for waybar process.
///
/// Useful when you want to defer the process search, or when waybar
/// may not be running at initialization time.
pub fn initLazy(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();

    return .{
        .io = io,
        .config = config,
        .process_handle = null,
        .check_counter = 0,
    };
}

/// Send update signal to waybar.
///
/// If waybar is available, sends the configured real-time signal.
/// If waybar is not available, periodically attempts to re-discover it
/// based on `check_interval`.
///
/// Silently handles the case where waybar process has died since last check.
pub fn update(this: *Waybar) !void {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            this.invalidateHandle();
            return;
        };
        return;
    }

    this.tryRediscover();
}

/// Attempt to send update signal, returning success status.
///
/// Unlike `update()`, this method returns whether the signal was actually sent.
/// Useful when you need to know if waybar received the update.
pub fn tryUpdate(this: *Waybar) bool {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            this.invalidateHandle();
            return false;
        };
        return true;
    }

    this.tryRediscover();
    return false;
}

/// Send update, forcing a refresh if waybar is not available.
///
/// This combines `refresh()` and `update()` - if waybar is not currently
/// tracked, it will immediately search for it rather than waiting for
/// the check interval.
pub fn updateOrRefresh(this: *Waybar) !void {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            this.invalidateHandle();
            try this.refresh();
            return this.update();
        };
        return;
    }

    try this.refresh();
    try this.update();
}

/// Force refresh waybar handle by searching for the process.
///
/// Use this when you know waybar has been (re)started and want
/// to immediately reconnect without waiting for the check interval.
pub fn refresh(this: *Waybar) !void {
    this.process_handle = try Process.findByName(this.io, "waybar");
    this.check_counter = 0;
}

/// Check if waybar process is currently being tracked.
///
/// Note: This only indicates if we have a cached process handle.
/// The process may have died since we last checked.
pub fn isAvailable(this: *const Waybar) bool {
    return this.process_handle != null;
}

/// Get the underlying process handle if available.
///
/// Useful for advanced operations like checking if the process is alive
/// or sending custom signals.
pub fn getProcess(this: *const Waybar) ?Process.Process {
    return this.process_handle;
}

/// Get current signal number (offset from SIGRTMIN)
pub fn getSignalNumber(this: *const Waybar) u8 {
    return this.config.signal_number;
}

/// Get the actual signal value that will be sent (SIGRTMIN + offset)
pub fn getActualSignal(this: *const Waybar) i32 {
    return @intCast(linux.sigrtmin() + this.config.signal_number);
}

/// Update signal number at runtime.
///
/// The new signal number must be valid (1-31 and within RT signal range).
pub fn setSignalNumber(this: *Waybar, signal: u8) WaybarError!void {
    if (!isValidSignal(signal)) return WaybarError.InvalidSignalNumber;

    this.config.signal_number = signal;
}

/// Get the current check interval
pub fn getCheckInterval(this: *const Waybar) u32 {
    return this.config.check_interval;
}

/// Update the check interval at runtime
pub fn setCheckInterval(this: *Waybar, interval: u32) void {
    this.config.check_interval = interval;
}

/// Reset the check counter, causing the next update to attempt rediscovery
pub fn resetCheckCounter(this: *Waybar) void {
    this.check_counter = this.config.check_interval;
}

/// Invalidate the cached process handle and reset check counter
fn invalidateHandle(this: *Waybar) void {
    this.process_handle = null;
    this.check_counter = 0;
}

/// Attempt to rediscover the waybar process
fn tryRediscover(this: *Waybar) void {
    this.check_counter += 1;
    if (this.check_counter >= this.config.check_interval) {
        this.check_counter = 0;
        if (Process.findByName(this.io, "waybar")) |maybe_handle| {
            if (maybe_handle) |handle| {
                this.process_handle = handle;
                handle.sendRtSignal(this.config.signal_number) catch {};
            }
        } else |_| {}
    }
}
