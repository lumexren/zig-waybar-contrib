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

const Fan = @import("sysinfo").Fan;

const std = @import("std");
const utils = @import("utils");
const Module = utils.Module;
const process = std.process;
const ArrayList = std.ArrayList;

pub const ModuleConfig = struct {
    update_interval: i64 = 2,
    warning_threshold: ?i64 = 3000,
    critical_threshold: ?i64 = 5000,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {total_fans}",
    tooltip: []const u8 = "{name}: {speed} RPM",
};

pub fn main(init: process.Init) !void {
    var mod = try Module(ModuleConfig).init(init, "fan");
    defer mod.deinit();

    var fans: ArrayList(Fan.FanInfo) = .empty;
    var fan: Fan = .init(init.io, init.gpa, &fans);
    defer fan.deinit();

    var tooltip_text: ArrayList(u8) = .empty;
    defer tooltip_text.deinit(init.gpa);

    while (try mod.tick()) {
        fan.clear();
        tooltip_text.clearRetainingCapacity();

        try fan.scan();

        try mod.put("total_fans", fans.items.len);

        var max_speed: i64 = 0;
        for (fan.fans.items) |f| {
            if (f.speed > max_speed) max_speed = f.speed;

            try mod.putString("name", f.name);
            try mod.put("speed", f.speed);

            const line = try mod.replacer.render(mod.config.tooltip);
            defer mod.replacer.free(line);

            if (tooltip_text.items.len > 0) try tooltip_text.append(init.gpa, '\n');
            try tooltip_text.appendSlice(init.gpa, line);
        }

        try mod.render(.{
            .percentage = @floatFromInt(max_speed),
            .custom_tooltip = tooltip_text.items,
        });
    }
}
