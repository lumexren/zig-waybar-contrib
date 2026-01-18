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

/// Interfaces with NVIDIA's NVML to collect runtime GPU metrics.
const Module = @This();

const c = @cImport({
    @cInclude("nvml.h");
});

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

allocator: Allocator,
handle: c.nvmlDevice_t = null,

const lib = @import("../lib.zig");
const GPUError = lib.GPUError;

pub fn init(allocator: Allocator) Module {
    return .{ .allocator = allocator };
}

pub fn shutdown(_: *Module) void {
    _ = c.nvmlShutdown();
}

pub fn initialize(this: *Module) !void {
    if (c.nvmlInit() != c.NVML_SUCCESS) return GPUError.InitFailed;

    var device_count: c_uint = 0;
    if (c.nvmlDeviceGetCount(&device_count) != c.NVML_SUCCESS or device_count == 0) return GPUError.NoDevices;

    var handle: c.nvmlDevice_t = undefined;
    if (c.nvmlDeviceGetHandleByIndex(0, &handle) != c.NVML_SUCCESS) return GPUError.HandleFailed;

    this.handle = handle;
}

pub fn getInfo(this: *Module) !lib.GPUInfo {
    var util: c.nvmlUtilization_t = undefined;
    _ = c.nvmlDeviceGetUtilizationRates(this.handle, &util);

    var temperature: c_uint = 0;
    _ = c.nvmlDeviceGetTemperature(this.handle, c.NVML_TEMPERATURE_GPU, &temperature);
    temperature = @floatFromInt(temperature);

    var mem_info: c.nvmlMemory_t = undefined;
    _ = c.nvmlDeviceGetMemoryInfo(this.handle, &mem_info);

    var fan_speed: c_uint = 0;
    const fan_result = c.nvmlDeviceGetFanSpeed(this.handle, &fan_speed);

    var pwm: u64 = 0;
    if (fan_result == c.NVML_SUCCESS) pwm = fan_speed;

    const memory_info = lib.GPUMemoryInfo{
        .free = mem_info.free,
        .total = mem_info.total,
        .used = mem_info.used,
    };

    return lib.GPUInfo{
        .gpu_busy = util.gpu,
        .temperature = temperature,
        .pwm = pwm,
        .memory_info = memory_info,
    };
}
