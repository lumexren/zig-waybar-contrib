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

pub const CPU = @import("cpu.zig");
pub const disk = @import("disk.zig");
pub const Memory = @import("memory.zig");
pub const Fan = @import("fan.zig");
pub const network = @import("network/network.zig");
pub const Updates = @import("updates.zig");
pub const gpu = @import("gpu/gpu.zig").SMI;
pub const mpris = @import("mpris.zig");
pub const battery = @import("battery.zig");
pub const Backlight = @import("backlight.zig");
pub const bluetooth = @import("bluetooth.zig");
