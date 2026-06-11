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
/// Handles process discovery, caching, and transparent periodic reconnection.
const Waybar = @This();

const std = @import("std");
const Process = @import("Process.zig");

const linux = std.os.linux;
const Io = std.Io;

const waybar_comm = "waybar";

/// I/O handle for all filesystem and process operations.
io: Io,
/// Cached waybar process handle.  Null when waybar is not known to be running.
process_handle: ?Process.Process,
/// RT signal offset from SIGRTMIN (e.g. 1 → SIGRTMIN+1).
signal_number: u8,
/// update() calls to skip between /proc scans when waybar is not found.
check_interval: u32,
/// Rolling counter incremented on every call to rediscover().
check_counter: u32,

/// Errors that can be returned by Waybar operations.
pub const WaybarError = error{
    /// Signal offset is outside the kernel's valid RT range (must be ≥ 1).
    InvalidSignalNumber,
    /// Explicit refresh found no running waybar process.
    WaybarNotFound,
};

/// Init-time configuration.
pub const Config = struct {
    /// Real-time signal offset (SIGRTMIN + offset). Must be ≥ 1.
    signal_number: u8,
    /// update() calls to skip before re-scanning /proc for waybar.
    /// Raise this to reduce /proc overhead when waybar is rarely restarted.
    check_interval: u32 = 10,

    /// Validate that signal_number is within the kernel's RT signal range.
    pub inline fn validate(this: @This()) WaybarError!void {
        if (!isValidSignal(this.signal_number)) return WaybarError.InvalidSignalNumber;
    }
};

/// Create a handle and immediately scan /proc for waybar.
/// Does not fail if waybar is not running — check `isAvailable()` afterward.
pub fn init(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();
    const handle = Process.findByName(io, waybar_comm) catch null;
    return .{
        .io = io,
        .process_handle = handle,
        .signal_number = config.signal_number,
        .check_interval = config.check_interval,
        .check_counter = 0,
    };
}

/// Create a handle without scanning for waybar.
/// The first rediscovery cycle begins after `check_interval` update() calls.
pub fn initLazy(io: Io, config: Config) WaybarError!Waybar {
    try config.validate();
    return .{
        .io = io,
        .process_handle = null,
        .signal_number = config.signal_number,
        .check_interval = config.check_interval,
        .check_counter = 0,
    };
}

/// Send the configured RT signal to waybar.
///
/// When a live handle is cached the signal is sent immediately.
/// When the handle has died it is dropped and the periodic rediscovery
/// counter is incremented.  When no handle exists the counter is ticked
/// and a /proc scan fires once it reaches `check_interval`.
///
/// Signal delivery errors (e.g. ESRCH when waybar just exited) are absorbed
/// silently.  Use `tryUpdate` when you need to know whether the signal landed.
pub fn update(this: *Waybar) void {
    if (this.process_handle) |h| {
        h.sendRtSignal(this.signal_number) catch this.invalidate();
        return;
    }
    _ = this.rediscover();
}

/// Like `update()` but returns `true` when the signal was successfully sent.
pub fn tryUpdate(this: *Waybar) bool {
    if (this.process_handle) |h| {
        h.sendRtSignal(this.signal_number) catch {
            this.invalidate();
            return false;
        };
        return true;
    }
    return this.rediscover();
}

/// Signal waybar, performing an immediate /proc scan when no handle is cached
/// instead of waiting for the rediscovery interval.
///
/// Returns `WaybarError.WaybarNotFound` if the forced scan finds no process.
/// Signal delivery errors after a successful discovery are silently absorbed.
pub fn updateOrRefresh(this: *Waybar) WaybarError!void {
    if (this.process_handle) |h| {
        h.sendRtSignal(this.signal_number) catch {
            this.invalidate();
            return this.forceRefresh();
        };
        return;
    }
    return this.forceRefresh();
}

/// Force an immediate /proc scan, update the cached handle, and send the signal.
/// Returns `WaybarError.WaybarNotFound` if no waybar process is running.
/// Signal delivery errors after discovery are absorbed (process may have just died again).
pub fn refresh(this: *Waybar) WaybarError!void {
    return this.forceRefresh();
}

/// Returns true when a waybar process handle is cached.
/// The process may have died since the last signal; use `tryUpdate` to confirm.
pub inline fn isAvailable(this: *const Waybar) bool {
    return this.process_handle != null;
}

/// Returns the resolved kernel signal number (SIGRTMIN + signal_number).
pub inline fn getActualSignal(this: *const Waybar) i32 {
    return linux.sigrtmin() + @as(i32, this.signal_number);
}

/// Change the signal offset at runtime. Validates the new value.
pub inline fn setSignalNumber(this: *Waybar, sig: u8) WaybarError!void {
    if (!isValidSignal(sig)) return WaybarError.InvalidSignalNumber;
    this.signal_number = sig;
}

/// Make the next `update()` call trigger an immediate /proc scan.
pub inline fn forceRediscovery(this: *Waybar) void {
    this.check_counter = this.check_interval;
}

/// Returns true when `sig` is within the kernel's usable RT signal range.
pub fn isValidSignal(sig: u8) bool {
    return sig >= 1 and (linux.sigrtmin() + @as(i32, sig)) <= linux.sigrtmax();
}

/// Scan /proc for waybar, cache the result, and signal it.
/// Clears check_counter regardless of outcome.
fn forceRefresh(this: *Waybar) WaybarError!void {
    this.check_counter = 0;
    const found = Process.findByName(this.io, waybar_comm) catch null;
    this.process_handle = found;
    if (found) |h| h.sendRtSignal(this.signal_number) catch this.invalidate();
}

/// Tick the rediscovery counter; scan /proc once it reaches `check_interval`.
/// Returns true when the signal was successfully sent after discovery.
fn rediscover(this: *Waybar) bool {
    this.check_counter += 1;
    if (this.check_counter < this.check_interval) return false;

    this.check_counter = 0;
    const found = Process.findByName(this.io, waybar_comm) catch return false;
    const h = found orelse return false;

    this.process_handle = h;
    h.sendRtSignal(this.signal_number) catch {
        this.invalidate();
        return false;
    };
    return true;
}

/// Drop the cached handle and reset the rediscovery counter.
inline fn invalidate(this: *Waybar) void {
    this.process_handle = null;
    this.check_counter = 0;
}

// Tests

const testing = std.testing;

test "isValidSignal: zero is rejected" {
    try testing.expect(!isValidSignal(0));
}

test "isValidSignal: one is accepted" {
    try testing.expect(isValidSignal(1));
}

test "Config.validate: zero signal errors" {
    const cfg: Config = .{ .signal_number = 0 };
    try testing.expectError(WaybarError.InvalidSignalNumber, cfg.validate());
}

test "Config.validate: signal one passes" {
    const cfg: Config = .{ .signal_number = 1 };
    try cfg.validate();
}

test "all public symbols compile" {
    _ = &init;
    _ = &initLazy;
    _ = &update;
    _ = &tryUpdate;
    _ = &updateOrRefresh;
    _ = &refresh;
    _ = &isAvailable;
    _ = &getActualSignal;
    _ = &setSignalNumber;
    _ = &forceRediscovery;
    _ = &isValidSignal;
}
