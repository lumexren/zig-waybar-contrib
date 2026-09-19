// SPDX-License-Identifier: GPL-3.0-only
//
// This file is part of zig-waybar-contrib.
//
// Copyright (c) 2026 erenvly
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

pub const GPUError = @import("GPUError.zig").GPUError;
pub const GPUInfo = @import("GPUInfo.zig");
pub const GPUMemoryInfo = @import("GPUMemoryInfo.zig");

const smi = @import("bindings").nvml;

handle: smi.nvmlDevice_t = null,

pub inline fn init(_: anytype) Backend {
    return .{};
}

pub inline fn shutdown(_: *Backend) void {
    _ = smi.nvmlShutdown();
}

pub fn initialize(this: *Backend) !void {
    if (smi.nvmlInit() != smi.NVML_SUCCESS) return GPUError.InitFailed;

    var device_count: c_uint = 0;
    if (smi.nvmlDeviceGetCount(&device_count) != smi.NVML_SUCCESS or device_count == 0) return GPUError.NoDevices;

    var handle: smi.nvmlDevice_t = undefined;
    if (smi.nvmlDeviceGetHandleByIndex(0, &handle) != smi.NVML_SUCCESS) return GPUError.HandleFailed;

    this.handle = handle;
}

pub fn getInfo(this: *Backend) !GPUInfo {
    var util: smi.nvmlUtilization_t = undefined;
    _ = smi.nvmlDeviceGetUtilizationRates(this.handle, &util);

    var raw_temp: c_uint = 0;
    _ = smi.nvmlDeviceGetTemperature(this.handle, smi.NVML_TEMPERATURE_GPU, &raw_temp);

    var mem_info: smi.nvmlMemory_t = undefined;
    _ = smi.nvmlDeviceGetMemoryInfo(this.handle, &mem_info);

    var fan_speed: c_uint = 0;
    const fan_ok = smi.nvmlDeviceGetFanSpeed(this.handle, &fan_speed) == smi.NVML_SUCCESS;

    return .{
        .gpu_busy = util.gpu,
        .temperature = @floatFromInt(raw_temp),
        .pwm = if (fan_ok) fan_speed else 0,
        .memory_info = .{
            .free = mem_info.free,
            .total = mem_info.total,
            .used = mem_info.used,
        },
    };
}
