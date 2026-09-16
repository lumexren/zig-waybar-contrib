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

/// A wrapper allocator that tracks allocation count, bytes allocated, peak memory, and leaks.
const TrackingAllocator = @This();

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Alignment = mem.Alignment;

parent_allocator: Allocator,
total_allocated: usize = 0,
total_freed: usize = 0,
current_allocated: usize = 0,
peak_allocated: usize = 0,
alloc_count: usize = 0,
free_count: usize = 0,

pub fn init(parent: Allocator) TrackingAllocator {
    return .{ .parent_allocator = parent };
}

pub fn allocator(this: *TrackingAllocator) Allocator {
    return .{
        .ptr = this,
        .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
    };
}

pub fn reset(this: *TrackingAllocator) void {
    this.total_allocated = 0;
    this.total_freed = 0;
    this.current_allocated = 0;
    this.peak_allocated = 0;
    this.alloc_count = 0;
    this.free_count = 0;
}

pub fn leakedBytes(this: *const TrackingAllocator) usize {
    if (this.total_allocated > this.total_freed) {
        return this.total_allocated - this.total_freed;
    }
    return 0;
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    const this: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = this.parent_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
    this.total_allocated += len;
    this.current_allocated += len;
    this.alloc_count += 1;
    if (this.current_allocated > this.peak_allocated) {
        this.peak_allocated = this.current_allocated;
    }
    return result;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
    const this: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    if (this.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) {
        if (new_len > buf.len) {
            const diff = new_len - buf.len;
            this.total_allocated += diff;
            this.current_allocated += diff;
            if (this.current_allocated > this.peak_allocated) {
                this.peak_allocated = this.current_allocated;
            }
        } else {
            const diff = buf.len - new_len;
            this.total_freed += diff;
            this.current_allocated -= diff;
        }
        return true;
    }
    return false;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const this: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    const result = this.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr);
    if (result != null) {
        if (new_len > memory.len) {
            const diff = new_len - memory.len;
            this.total_allocated += diff;
            this.current_allocated += diff;
            if (this.current_allocated > this.peak_allocated) {
                this.peak_allocated = this.current_allocated;
            }
        } else if (new_len < memory.len) {
            const diff = memory.len - new_len;
            this.total_freed += diff;
            this.current_allocated -= diff;
        }
    }
    return result;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
    const this: *TrackingAllocator = @ptrCast(@alignCast(ctx));
    this.parent_allocator.rawFree(buf, buf_align, ret_addr);
    this.total_freed += buf.len;
    this.current_allocated -= buf.len;
    this.free_count += 1;
}
