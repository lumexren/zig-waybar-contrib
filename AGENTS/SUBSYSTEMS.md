# Subsystems Deep Dive

This document provides a technical deep dive into the core reusable subsystems located in `src/utils/`, `src/bindings/`, and external dependencies like `plume`.

---

## 1. `utils.Config` (`src/utils/config/root.zig`)

The configuration subsystem handles discovering, reading, and parsing user configuration files formatted as Zig Object Notation (`.zon`).

### Path Resolution
1. Checks `$XDG_CONFIG_HOME`.
2. Falls back to `$HOME/.config`.
3. Targets the path: `<config_dir>/zig-waybar-contrib/<module_name>.zon`.

### Key Functions
- `init(io: Io, environ_map: *Map, allocator: Allocator) Config`: Initializes the config manager.
- `load(this: *Config, module_name: []const u8, comptime T: type) T`: Attempts to parse `<module_name>.zon` into struct `T`. If the file does not exist, has bad syntax, or fails, it cleanly frees any partial allocation and returns `T{}` (the default struct).
- `loadExact(this: *Config, module_name: []const u8, comptime T: type) !T`: Same as `load`, but bubbles up errors.
- `free(this: *Config, _: anytype) void`: Deinitializes the internal `ArenaAllocator` holding parsed strings.
- `exists(this: *Config, module_name: []const u8) bool`: Checks if a configuration file exists on disk.

---

## 2. `utils.Json` (`src/utils/json/root.zig`)

A specialized, incremental JSON serializer tailored for Waybar's streaming JSON contract.

### Capabilities & Value Support
- Native primitives: Integers (`i8`..`i64`, `usize`), Floats (via strings), Booleans (`true`/`false`).
- Strings: Duplicated and escaped for control characters (`"`, `\`, `\n`, `\r`, `\t`, `\b`, `\f`, unicode control points).
- String arrays: For multiple CSS classes (`["normal", "active"]`).

### API Highlights
- `set(key: []const u8, value: anytype) !void`: Adds or sets a JSON key-value pair.
- `setClass(class_name: []const u8) !void`: Sets `"class": "class_name"`.
- `setClasses(classes: []const []const u8) !void`: Sets `"class": ["class1", "class2"]`.
- `appendFmt(key, fmt, args)` / `appendFmtNL(key, fmt, args)`: Concatenates formatted strings to an existing string field. `appendFmtNL` automatically prepends `\n` on the second and subsequent calls—ideal for multi-line tooltips.
- `write(writer: *Io.Writer) !void`: Emits compact JSON followed by `\n`.
- `clear() void`: Frees owned strings while preserving the internal capacity for the next tick.

---

## 3. `utils.Replacer` (`src/utils/replacer/root.zig`)

The template replacement engine powers dynamic format strings like `text = "{icon}  {usage_percentage:'%'} {dot} {frequency:2:frequency_unit}"`.

### Placeholder Syntax & Features
- **Basic Placeholder:** `{name}` is replaced by the value stored under `"name"`.
- **Numeric Precision:** `{val:2}` formats a float to 2 decimal places.
- **Literal Appending:** `{val:'%'}` appends `%` immediately after the resolved value.
- **Specifier Chaining:** `{frequency:2:frequency_unit}` formats the float `frequency` to 2 decimal places and appends the string from `frequency_unit`.
- **Literal Escaping:** `{{` produces `{`, `}}` produces `}`.
- **Common Placeholders:** `replacer.addCommonPlaceholders()` adds:
  - `{dot}` → `•`
  - `{sep}` → `|`
  - `{nl}` → `\n`

### Performance Characteristics
- Uses a `StringHashMap(Value)` for $O(1)$ placeholder lookups.
- Pre-scans template size to avoid multiple reallocations during `render()`.
- Supports `clear()` which frees keys and values while retaining hash table capacity.

---

## 4. `utils.Watcher` (`src/utils/watcher/root.zig`)

Responsible for the event-driven, zero-overhead sleeping mechanism.

### How It Works
1. Upon `init()`, masks both `SIGUSR1` and `SIGUSR2` in the calling thread via `posix.sigprocmask(SIG.BLOCK)`.
2. Creates a Linux `signalfd` file descriptor (`SFD_NONBLOCK | SFD_CLOEXEC`).
3. In `waitSeconds(seconds)`:
   - Polls the `signalfd` with a timeout of `seconds * 1000` ms.
   - If a signal arrives (e.g., Waybar triggering an update via `SIGUSR1`), it drains the signal buffer and immediately returns `true` (woke early).
   - If the timer elapses naturally without any signal, it returns `false`.
4. Consumes **0% CPU** while sleeping.

---

## 5. `utils.Process` (`src/utils/process/root.zig`)

Provides process querying and subprocess helpers:
- `ProcessIterator`: Scans `/proc` to enumerate running processes, PIDs, and process names.
- `findByName(allocator, name)`: Finds the first matching process PID.
- `findAllByName(allocator, name)`: Returns all PIDs matching a process name.
- `findExecutable(io, name)`: Resolves an executable in system `$PATH`.
- `runCommandCapture(allocator, io, argv)`: Runs a command and returns captured stdout/stderr.

---

## 6. D-Bus Integration via `plume`

The project imports `plume` (defined in `build.zig.zon`), an asynchronous and synchronous D-Bus client implementation in pure Zig:
- Used by `src/sysinfo/pipewire` for PulseAudio/PipeWire volume management.
- Used by `src/sysinfo/bluetooth` to track BlueZ adapters and paired devices.
- Used by `src/sysinfo/mpris` to query MPRIS media player state (`org.mpris.MediaPlayer2`).
- Used by `src/sysinfo/battery` for UPower monitoring.

---

## 7. C Bindings (`src/bindings/`)

When low-level OS or hardware metrics require C library linkage:
- **`src/bindings/nvml.zig`**: C headers and type definitions for NVIDIA Management Library (`libnvidia-ml.so`).
- **`src/bindings/amdsmi.zig`**: C headers for AMD SMI (`libamd_smi.so`).
- **`src/bindings/statvfs.zig`**: C wrapper calling POSIX `statvfs` to retrieve filesystem block size, total blocks, and available blocks for `disk` monitoring.

---

## 8. `utils.Module` (`src/utils/module/root.zig`)

The unified runtime harness for creating custom Waybar modules with minimal boilerplate.
- **`Module(ConfigType).init(init, "mod_name")`**: Loads ZON configuration, initializes `Watcher` (signalfd), `Json`, `Replacer`, and 4KB buffered stdout writer.
- **`mod.tick() !bool`**: Manages the main event loop, non-busy sleeps via `Watcher`, clears builder buffers, and re-registers common placeholders. Returns `false` for one-shot runs (`update_interval == 0`).
- **`mod.put(key, val)`**: Convenience wrapper for `replacer.addKeyAny`.
- **`mod.render(options)`**: Automatically evaluates `critical_threshold` and `warning_threshold`, renders user templates (`text` and `tooltip`), and emits flushed JSON.
- **`mod.renderError(text, tooltip)`**: Emits standard error status line on hardware/device unavailability.

---

## 9. `sysinfo.common` (`src/sysinfo/common/`)

Shared OS and sysfs interaction primitives for hardware metric collectors:
- **`sysfs.readInt(io, dir, filename, T)`**: Generic integer parser from sysfs.
- **`sysfs.readMilli(io, dir, filename)`**: Millidegree / milli-value reader using raw Linux read syscall to handle `ENODATA` and non-standard sysfs EOF cleanly without runtime panics.
- **`sysfs.readTrimmed(io, dir, filename, buf)`**: Trimmed string reader.
