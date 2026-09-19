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

pub fn init(_: anytype) Backend {
    return .{};
}

pub fn shutdown(_: *Backend) void {
    @panic("not implemented");
}

pub fn initialize(_: *Backend) !void {
    @panic("not implemented");
}

pub fn getInfo(_: *Backend) !GPUInfo {
    return .{};
}
