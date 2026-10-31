# AI Agent Guidelines & Codebase Knowledge Base

Welcome to the **`zig-waybar-contrib`** codebase knowledge base for AI agents. This directory (`AGENTS/`) provides a structured, high-signal guide to understanding, developing, debugging, and extending this project.

---

## 🧭 Navigation Index

| Document | Purpose |
| :--- | :--- |
| **[ARCHITECTURE.md](./ARCHITECTURE.md)** | Core architecture, data flow pipeline, signal-driven loops, and Waybar protocol integration. |
| **[PROJECT_STRUCTURE.md](./PROJECT_STRUCTURE.md)** | Directory tree breakdown, file roles, and module/sysinfo taxonomy. |
| **[BUILD_AND_TEST.md](./BUILD_AND_TEST.md)** | Toolchain versioning (Zig 0.18.x dev), build options, unit tests, and benchmarks. |
| **[CONVENTIONS.md](./CONVENTIONS.md)** | Zig 0.18 idioms (`std.Io`, GPA/arena lifetimes), naming conventions, and error handling rules. |
| **[SUBSYSTEMS.md](./SUBSYSTEMS.md)** | Deep dives into `Config`, `Json`, `Replacer`, `Watcher`, `Process`, `plume` (D-Bus), and C bindings. |
| **[CREATING_MODULES.md](./CREATING_MODULES.md)** | Step-by-step guide to implementing a new Waybar module from scratch. |

---

## ⚡ Project Overview

- **Project:** `zig-waybar-contrib`
- **Language:** **Zig** (Targeting **`0.18.0-dev`** on branch `0.18.x-staging`)
- **License:** GNU General Public License v3.0 (GPL-3.0-only)
- **Author:** lumexren
- **Goal:** High-performance, lightweight, memory-safe custom Waybar modules running as independent standalone binaries communicating with Waybar via streaming JSON on `stdout`.
- **Key Philosophy:**
  - **Zero Idle CPU Overhead:** Real-time wakeups via Linux `signalfd` (`SIGUSR1` / `SIGUSR2`) or D-Bus events; non-busy sleeping.
  - **Low Memory Footprint:** Explicit memory allocations, allocation reuse (`clearRetainingCapacity`), minimal allocations inside update loops.
  - **Zero Unnecessary Runtime Dependencies:** Self-contained statically linked binaries where possible; dynamic C libraries optional for proprietary drivers (NVML, AMD-SMI, statvfs).

---

## 🚀 Quick Commands for Agents

```bash
# Check Zig version (Must match .zigversion: 0.18.0-dev.*)
zig version

# Build all modules (Debug/Default)
zig build

# Build optimized release binaries
zig build -Doptimize=small # or -Doptimize=fast

# Run test suite
zig build test

# Run performance benchmarks
zig build bench
zig build bench -- json      # Filter: json serialization benchmarks
zig build bench -- replacer  # Filter: replacer template benchmarks
zig build bench -- sysinfo   # Filter: sysinfo benchmarks

# Format all code according to Zig standard style
zig fmt .
```

---

## ⚠️ Critical Rules & Gotchas for AI Agents

1. **Zig Version Specifics:**
   - The codebase uses the cutting-edge abstraction introduced (e.g. `std.Io`, `init: std.process.Init`, `Io.File.writer`, `std.Io.Dir.openFileAbsolute`).
   - Do **NOT** revert to legacy `std.fs.cwd()` or `std.io.getStdOut()` idioms from Zig 0.11-0.13. Always inspect existing modules (such as `src/modules/cpu.zig`) for current I/O paradigms.

2. **Memory Management & Ownership:**
   - Always pair `init` with `defer deinit()`.
   - In looping modules, use `clearRetainingCapacity()` or `clear()` to avoid reallocating internal buffers on each tick.
   - Configuration structs loaded via `Config.load(...)` use an `ArenaAllocator`; call `defer config.free(data)` once loaded.

3. **Error Handling:**
   - Define module-specific error sets (e.g. `CPUError`, `NetworkError`, `ReplacerError`).
   - Do not use `catch unreachable` in production code unless proven mathematically impossible to fail. Propagate errors via `!` or handle gracefully with default fallbacks.

4. **Code Formatting:**
   - Always run `zig fmt <file>` after editing any `.zig` files to ensure compliance with repository style.

5. **Licensing Header:**
   - Every `.zig` source file begins with the GPL-3.0 header block:
     ```zig
     // SPDX-License-Identifier: GPL-3.0-only
     //
     // This file is part of zig-waybar-contrib.
     //
     // Copyright (c) 2026 lumexren
     ...
     ```

6. **Imports & Initializer Syntax:**
   - Standard library symbols must be aliased at the top of the file (e.g., `const ArrayList = std.ArrayList;`). Avoid calling `std.<namespace>` inline.
   - Use result location type inference for initializers: `var x: Type = .init(...);` and `var fans: ArrayList(FanInfo) = .empty;`. For initializers chained with `catch` inline, retain the type prefix `Type.init(...)`.
