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

const Backend = @This();

const smi = @import("bindings").amdsmi;

const std = @import("std");
const Allocator = std.mem.Allocator;

allocator: Allocator,
handle: smi.amdsmi_processor_handle = null,

pub const GPUError = error{
    HandleFailed,
    InitFailed,
    NoDevices,
};

pub const GPUInfo = struct {
    gpu_busy: u64,
    temperature: f32,
    pwm: u64,
    memory_info: GPUMemoryInfo,
};

pub const GPUMemoryInfo = struct {
    total: u64,
    used: u64,
    free: u64,
};

pub inline fn init(allocator: Allocator) Backend {
    return .{ .allocator = allocator };
}

pub inline fn shutdown(_: *Backend) void {
    _ = smi.amdsmi_shut_down();
}

pub fn initialize(this: *Backend) !void {
    if (smi.amdsmi_init(smi.AMDSMI_INIT_AMD_GPUS) != smi.AMDSMI_STATUS_SUCCESS) return GPUError.InitFailed;

    var socket_count: u32 = 0;
    _ = smi.amdsmi_get_socket_handles(&socket_count, null);
    if (socket_count == 0) return GPUError.NoDevices;

    const sockets = try this.allocator.alloc(smi.amdsmi_socket_handle, socket_count);
    defer this.allocator.free(sockets);
    _ = smi.amdsmi_get_socket_handles(&socket_count, sockets.ptr);

    var proc_count: u32 = 0;
    _ = smi.amdsmi_get_processor_handles(sockets[0], &proc_count, null);
    if (proc_count == 0) return GPUError.NoDevices;

    const procs = try this.allocator.alloc(smi.amdsmi_processor_handle, proc_count);
    defer this.allocator.free(procs);
    _ = smi.amdsmi_get_processor_handles(sockets[0], &proc_count, procs.ptr);

    this.handle = procs[0];
}

pub fn getInfo(this: *Backend) !GPUInfo {
    var raw_temp: i64 = 0;
    const temperature: f32 = if (smi.amdsmi_get_temp_metric(this.handle, smi.AMDSMI_TEMPERATURE_TYPE_EDGE, smi.AMDSMI_TEMP_CURRENT, &raw_temp) == smi.AMDSMI_STATUS_SUCCESS) @floatFromInt(raw_temp) else 0;

    var raw_busy: u32 = 0;
    const gpu_busy: u64 = if (smi.amdsmi_get_gpu_busy_percent(this.handle, &raw_busy) == smi.AMDSMI_STATUS_SUCCESS)
        raw_busy
    else
        0;

    var mem_total: u64 = 0;
    var mem_used: u64 = 0;
    _ = smi.amdsmi_get_gpu_memory_total(this.handle, smi.AMDSMI_MEM_TYPE_VRAM, &mem_total);
    _ = smi.amdsmi_get_gpu_memory_usage(this.handle, smi.AMDSMI_MEM_TYPE_VRAM, &mem_used);

    return .{
        .temperature = temperature,
        .gpu_busy = gpu_busy,
        .pwm = fanPwm(this.handle),
        .memory_info = .{
            .total = mem_total,
            .used = mem_used,
            .free = if (mem_total > mem_used) mem_total - mem_used else 0,
        },
    };
}

inline fn fanPwm(handle: smi.amdsmi_processor_handle) u64 {
    var speed: i64 = 0;
    var max: u64 = 0;

    const speed_ok = smi.amdsmi_get_gpu_fan_speed(handle, 0, &speed) == smi.AMDSMI_STATUS_SUCCESS;
    const max_ok = smi.amdsmi_get_gpu_fan_speed_max(handle, 0, &max) == smi.AMDSMI_STATUS_SUCCESS;

    if (!speed_ok or !max_ok or max == 0) return 0;

    const pct = @divTrunc(@as(i128, speed) * 100, @as(i128, max));
    return @min(@as(u64, @intCast(pct)), 100);
}
