# Coding Conventions & Zig Idioms

This document details the code conventions, memory safety guidelines, and modern Zig idioms applied throughout `zig-waybar-contrib`.

---

## 1. Modern Zig 0.18 I/O Idioms

This project targets Zig **`0.18.0-dev`**, which fundamentally revamps standard I/O and process initialization. 

### Process Entrypoint
Do **NOT** use `pub fn main() !void` with global allocators or `std.io.getStdOut()`.
Always use the `process.Init` signature:
```zig
const std = @import("std");
const process = std.process;
const Io = std.Io;
const File = Io.File;

pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env_map = init.environ_map;
    ...
}
```

### Buffered Output Pattern
To eliminate syscall overhead in tight loops, always wrap `stdout` with a stack-allocated buffer:
```zig
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
const stdout = &stdout_writer.interface;

// Usage:
try json.write(stdout);
try stdout.flush();
```

### File Operations via `std.Io`
File and directory access requires the active `io: Io` handle:
```zig
// Opening a file:
var file = try Dir.openFileAbsolute(io, path, .{ .mode = .read_only });
defer file.close(io);

// Reading into a stack buffer:
var buffer: [2048]u8 = undefined;
var reader = file.reader(io, &.{});
const bytes_read = try reader.interface.readSliceShort(&buffer);
```

---

## 2. Memory Management Guidelines

Waybar modules run persistently in the background. Memory discipline is vital to prevent memory bloat or memory leaks.

### Loop-Level Allocation Discipline
Never leak heap memory inside the main polling loop:
```zig
while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
    // 1. Always clear reusable structures at loop scope
    defer json.clear();
    defer replacer.clear();

    // 2. Explicitly free intermediate buffers created in this iteration
    const line = try replacer.render(data.text);
    defer replacer.free(line);

    ...
}
```
`json.clear()` and `replacer.clear()` use `clearRetainingCapacity()`, which frees owned elements while preserving the underlying array capacity to eliminate reallocation overhead in subsequent cycles.

### Stack Buffers for Sysfs/Procfs
Reading Linux pseudo-filesystems (`/proc/stat`, `/proc/meminfo`, `/sys/class/...`) should always use stack buffers whenever possible (e.g., `var buf: [4096]u8 = undefined;`). Avoid `allocator.alloc` unless the file size is truly dynamic and unbounded.

### Arena Allocators for Configuration
The `Config` utility parses `.zon` configuration files using an `ArenaAllocator`. When reloading or freeing config, calling `config.free(data)` wipes out all heap strings at once, avoiding fine-grained deallocation bugs.

---

## 3. Error Handling

### Explicit Domain Error Sets
Define typed error sets for each module rather than using generic `anyerror`:
```zig
pub const CPUError = error{
    StatFileNotFound,
    InvalidStatFormat,
    CoreCountMismatch,
    FrequencyUnavailable,
};
```

### Graceful Degradation
Waybar modules should be resilient against missing hardware sensors or optional metrics:
- If a sensor or sysfs entry is absent (e.g. secondary fan, battery discharge rate), log a debug message or fallback to `null` rather than crashing the module.
- If a critical failure occurs (e.g. `/proc/stat` cannot be read at all), propagate the error out of `main` or retry gracefully on the next cycle.

---

## 4. Code Formatting & Headers

### License Header
Every Zig source file must begin with the standard license header:
```zig
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
```

### Formatting
Run `zig fmt .` before finalizing changes. Ensure consistent 4-space indentation and no trailing whitespaces.

---

## 5. Naming Conventions

| Identifier | Convention | Example |
| :--- | :--- | :--- |
| Structs, Enums, Types | `PascalCase` | `ModuleConfig`, `BatteryInfo`, `NetworkStats` |
| Functions, Methods | `camelCase` | `getDefaultRoute`, `addKeyAny`, `waitSeconds` |
| Variables, Fields, Params | `snake_case` | `update_interval`, `raw_bytes`, `core_usage` |
| Constants | `UPPER_SNAKE_CASE` or `camelCase` (types) | `MOUNTS_PATH`, `DEV_PATH`, `PULSE_SERVICE` |
