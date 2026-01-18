// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2025 - 2026 erffy
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

/// Interfaces with AMD SMI to collect runtime GPU metrics.
const Module = @This();

const c = @cImport({
    @cInclude("amd_smi/amdsmi.h");
});

const std = @import("std");
const lib = @import("../lib.zig");
const mem = std.mem;
const Allocator = mem.Allocator;

allocator: Allocator,
handle: c.amdsmi_processor_handle = null,

const GPUError = lib.GPUError;

pub fn init(allocator: Allocator) Module {
    return .{ .allocator = allocator };
}

pub fn shutdown(_: *Module) void {
    _ = c.amdsmi_shut_down();
}

pub fn initialize(this: *Module) !void {
    if (c.amdsmi_init(c.AMDSMI_INIT_AMD_GPUS) != c.AMDSMI_STATUS_SUCCESS) return GPUError.InitFailed;

    var socket_count: u32 = 0;
    _ = c.amdsmi_get_socket_handles(&socket_count, null);
    if (socket_count == 0) return GPUError.NoDevices;

    const sockets = try this.allocator.alloc(c.amdsmi_socket_handle, socket_count);
    _ = c.amdsmi_get_socket_handles(&socket_count, sockets.ptr);

    var proc_count: u32 = 0;
    _ = c.amdsmi_get_processor_handles(sockets[0], &proc_count, null);
    if (proc_count == 0) return GPUError.NoDevices;

    const procs = try this.allocator.alloc(c.amdsmi_processor_handle, proc_count);
    _ = c.amdsmi_get_processor_handles(sockets[0], &proc_count, procs.ptr);

    this.handle = procs[0];
}

pub fn getInfo(this: *Module) !lib.GPUInfo {
    var _temp: i64 = 0;
    var _gpu_busy: u32 = 0;
    var _mem_total: u64 = 0;
    var _mem_used: u64 = 0;
    var _fan_speed: i64 = 0;
    var _fan_max: u64 = 0;

    // Temperature
    var temperature: f64 = 0;

    const temp_result = c.amdsmi_get_temp_metric(this.handle, c.AMDSMI_TEMPERATURE_TYPE_EDGE, c.AMDSMI_TEMP_CURRENT, &_temp);
    if (temp_result == c.AMDSMI_STATUS_SUCCESS) temperature = @as(f64, @floatFromInt(_temp));

    // Busy info
    var gpu_busy: u64 = 0;

    const gpu_result = c.amdsmi_get_gpu_busy_percent(this.handle, &_gpu_busy);
    if (gpu_result == c.AMDSMI_STATUS_SUCCESS) gpu_busy = _gpu_busy;

    // Memory info
    var mem_free: u64 = 0;

    _ = c.amdsmi_get_gpu_memory_total(this.handle, c.AMDSMI_MEM_TYPE_VRAM, &_mem_total);
    _ = c.amdsmi_get_gpu_memory_usage(this.handle, c.AMDSMI_MEM_TYPE_VRAM, &_mem_used);

    if (_mem_total > _mem_used) mem_free = _mem_total - _mem_used;

    // PWM info
    var fan_pwm: u64 = 0;

    const fan_result = c.amdsmi_get_gpu_fan_speed(this.handle, 0, &_fan_speed);
    const fan_max_result = c.amdsmi_get_gpu_fan_speed_max(this.handle, 0, &_fan_max);

    if (fan_result == c.AMDSMI_STATUS_SUCCESS and fan_max_result == c.AMDSMI_STATUS_SUCCESS and _fan_max > 0) fan_pwm = @min(@as(u64, @intCast(@divTrunc(@as(i128, _fan_speed) * 100, @as(i128, _fan_max)))), 100);

    const memory_info = lib.GPUMemoryInfo{
        .free = mem_free,
        .total = _mem_total,
        .used = _mem_used,
    };

    return lib.GPUInfo{
        .temperature = temperature,
        .gpu_busy = gpu_busy,
        .pwm = fan_pwm,
        .memory_info = memory_info,
    };
}
