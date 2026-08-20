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

pub const CPU = @import("cpu/root.zig");
pub const disk = @import("disk/root.zig");
pub const Memory = @import("memory/root.zig");
pub const Fan = @import("fan/root.zig");
pub const network = @import("network/root.zig");
pub const Updates = @import("updates/root.zig");
pub const gpu = @import("gpu/root.zig").SMI;
pub const mpris = @import("mpris/root.zig");
pub const battery = @import("battery/root.zig");
pub const Backlight = @import("backlight/root.zig");
pub const bluetooth = @import("bluetooth/root.zig");
