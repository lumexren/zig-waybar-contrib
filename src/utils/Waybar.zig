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

/// Manages communication with the Waybar status bar through real-time signals.
/// Automatically handles waybar process discovery and reconnection.
const Waybar = @This();

const std = @import("std");
const Process = @import("Process.zig");
const os = std.os;
const linux = os.linux;
const Io = std.Io;

/// I/O handle for filesystem and process operations.
io: Io,
/// Cached waybar process handle, or null if not found/unavailable.
process_handle: ?Process.Process,
/// Configuration for signal number and reconnection behavior.
config: Config,
/// Counter for periodic rediscovery attempts.
check_counter: u32,

/// Errors returned by waybar operations.
pub const WaybarError = error{
    /// Signal number is outside the valid RT signal range (must be 1-31).
    InvalidSignalNumber,
    /// Waybar process is not running or cannot be found.
    WaybarNotFound,
    /// Failed to send signal to the waybar process.
    SignalFailed,
};

/// Configuration for Waybar operations.
pub const Config = struct {
    /// Real-time signal offset (SIGRTMIN + offset). Must be 1-31.
    signal_number: u8,
    /// Failed update attempts before re-searching for the waybar process.
    check_interval: u32 = 10,

    /// Validate that the signal number is in the valid RT range.
    pub inline fn validate(this: @This()) WaybarError!void {
        if (!isValidSignal(this.signal_number)) return WaybarError.InvalidSignalNumber;
    }
};

/// Check if a signal number is valid (1-31 range, fits within RT signal range).
pub fn isValidSignal(signal_number: u8) bool {
    if (signal_number < 1) return false;
    return (linux.sigrtmin() + signal_number) <= linux.sigrtmax();
}

/// Initialize and immediately search for the waybar process.
/// Does not error if waybar is not running — use `isAvailable()` to check.
pub fn init(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();
    const handle = Process.findByName(io, "waybar") catch null;
    return .{ .io = io, .config = config, .process_handle = handle, .check_counter = 0 };
}

/// Initialize without searching for the waybar process.
pub inline fn initLazy(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();
    return .{ .io = io, .config = config, .process_handle = null, .check_counter = 0 };
}

/// Send update signal to waybar.
/// If waybar is unavailable, periodically attempts rediscovery based on `check_interval`.
/// Silently handles a dead process since the last check.
pub fn update(this: *Waybar) !void {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch this.invalidateHandle();
        return;
    }

    _ = this.tryRediscover();
}

/// Like `update()`, but returns whether the signal was actually sent.
pub fn tryUpdate(this: *Waybar) bool {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            this.invalidateHandle();
            return false;
        };
        return true;
    }

    return this.tryRediscover();
}

/// Send update signal, forcing an immediate rediscovery if waybar is not tracked.
pub fn updateOrRefresh(this: *Waybar) !void {
    if (this.process_handle) |handle| {
        handle.sendRtSignal(this.config.signal_number) catch {
            this.invalidateHandle();
            try this.refresh();
            const h = this.process_handle orelse return;
            try h.sendRtSignal(this.config.signal_number);
        };
        return;
    }

    try this.refresh();
    const h = this.process_handle orelse return;
    try h.sendRtSignal(this.config.signal_number);
}

/// Force-search for the waybar process and reset the check counter.
pub fn refresh(this: *Waybar) !void {
    this.process_handle = try Process.findByName(this.io, "waybar");
    this.check_counter = 0;
}

/// Returns true if a cached waybar process handle exists.
/// The process may have died since the last check.
pub inline fn isAvailable(this: *const Waybar) bool {
    return this.process_handle != null;
}

/// Returns the actual signal number (SIGRTMIN + signal_number).
pub inline fn getActualSignal(this: *const Waybar) i32 {
    return @intCast(linux.sigrtmin() + this.config.signal_number);
}

/// Update the signal number. Validates that the new value is in range.
pub inline fn setSignalNumber(this: *Waybar, signal: u8) WaybarError!void {
    if (!isValidSignal(signal)) return WaybarError.InvalidSignalNumber;
    this.config.signal_number = signal;
}

/// Force the next update call to attempt rediscovery.
pub inline fn forceRediscovery(this: *Waybar) void {
    this.check_counter = this.config.check_interval;
}

/// Invalidate the cached process handle and reset the check counter.
inline fn invalidateHandle(this: *Waybar) void {
    this.process_handle = null;
    this.check_counter = 0;
}

/// Attempt periodic rediscovery. Returns true if the process was found and signaled.
fn tryRediscover(this: *Waybar) bool {
    this.check_counter += 1;
    if (this.check_counter < this.config.check_interval) return false;

    this.check_counter = 0;
    const handle = Process.findByName(this.io, "waybar") catch return false;

    this.process_handle = handle;
    handle.sendRtSignal(this.config.signal_number) catch return false;
    return true;
}