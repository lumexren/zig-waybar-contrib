# Architecture & Design

This document details the architectural design and runtime mechanics of `zig-waybar-contrib`.

---

## 1. High-Level Concept

Waybar supports custom modules through its `custom/` block using a streaming or periodic JSON interface:
```jsonc
"custom/cpu": {
    "exec": "/usr/bin/cpu",
    "return-type": "json",
    "interval": "once" // The binary itself handles update intervals and signal wakeups
}
```

Instead of running short-lived shell scripts that spawn subprocesses every second, `zig-waybar-contrib` compiles each module into an independent, hyper-optimized Zig binary. 

Each binary:
- Stays resident in memory.
- Uses Linux `signalfd` to sleep with zero CPU polling.
- Updates periodically according to `.zon` configuration.
- Instantly updates on receiving `SIGUSR1` (standard Waybar module signal trigger) or `SIGUSR2`.
- Emits newline-delimited JSON objects directly to `stdout`.

---

## 2. End-to-End Data Pipeline

The lifecycle of each module iteration proceeds through 5 distinct pipeline stages:

```
┌─────────────────┐
│   Kernel / OS   │  (/proc, /sys, D-Bus via plume, NVML, AMD-SMI, statvfs)
└────────┬────────┘
         │
         ▼  Stage 1: System Metrics Collection
┌─────────────────┐
│  src/sysinfo    │  (Extracts raw hardware metrics, calculates deltas, rates, averages)
└────────┬────────┘
         │
         ▼  Stage 2: Placeholder Population
┌─────────────────┐
│  utils.Replacer │  (Binds values: text, integers, floats, units, format specs)
└────────┬────────┘
         │
         ▼  Stage 3: Template Rendering
┌─────────────────┐
│  Template Engine│  (Interpolates configured user strings: data.text & data.tooltip)
└────────┬────────┘
         │
         ▼  Stage 4: JSON Serialization & Thresholding
┌─────────────────┐
│   utils.Json    │  (Encodes JSON: text, tooltip, percentage, class switch)
└────────┬────────┘
         │
         ▼  Stage 5: Buffered Output & Sleep / Wake
┌─────────────────┐
│  stdout / Waybar│  (Flushes to Waybar; sleeps via Watcher.waitSeconds(interval))
└─────────────────┘
```

---

## 3. Runtime Lifecycle & The Event Loop

A standard module entrypoint follows this canonical pattern:

```zig
pub fn main(init: process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 1. Buffered Stdout Writer (4KB buffer for minimal syscalls)
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = File.writer(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // 2. Load ZON configuration (fallback to defaults if not found)
    var config: Config = .init(io, init.environ_map, gpa);
    const data: ModuleConfig = config.load("mymodule", ModuleConfig);
    defer config.free(data);

    // 3. Initialize signal watcher (blocks SIGUSR1, SIGUSR2 and monitors via signalfd)
    var watcher = try Watcher.init();
    defer watcher.deinit();

    // 4. Initialize reusable builders
    var json: Json = .init(gpa);
    defer json.deinit();

    var replacer: Replacer = .init(gpa);
    defer replacer.deinit();

    var driver: MyDriver = .init(io, gpa);
    defer driver.deinit();

    // 5. Execution Loop
    while (true) : (_ = watcher.waitSeconds(data.update_interval)) {
        defer json.clear();
        defer replacer.clear();

        try driver.update();

        // Populate placeholders
        try replacer.addCommonPlaceholders();
        try replacer.addKey("icon", data.icon);
        try replacer.addKeyAny("val", driver.val);

        // Render user-configured templates
        const rendered_text = try replacer.render(data.text);
        defer replacer.free(rendered_text);

        try json.set("text", rendered_text);
        try json.set("percentage", driver.percentage);

        // Threshold evaluation (normal, warning, critical)
        if (data.critical_threshold) |crit| {
            if (driver.percentage >= crit) {
                try json.setClass("critical");
            } else if (driver.warning_threshold) |warn| {
                if (driver.percentage >= warn) try json.setClass("warning") else try json.setClass("normal");
            } else {
                try json.setClass("normal");
            }
        }

        // Emit JSON and flush buffer
        try json.write(stdout);
        try stdout.flush();

        // update_interval == 0 indicates one-shot execution
        if (data.update_interval == 0) break;
    }
}
```

---

## 4. Key Architectural Subsystems

### 4.1. Zero-CPU Sleep via `Watcher`
Traditional modules use `sleep(interval)` or `poll()` which ignore external Waybar events or waste CPU. `utils.Watcher`:
- Uses Linux `signalfd(2)` with `SFD_NONBLOCK | SFD_CLOEXEC`.
- Masks `SIGUSR1` and `SIGUSR2`.
- Uses `posix.poll` on the signal file descriptor with a millisecond timeout.
- Returns immediately if Waybar or a user sends `SIGUSR1` (e.g. `pkill -SIGUSR1 cpu`), triggering an instant interface update without waiting for the timeout.

### 4.2. Configuration via Zig Object Notation (`.zon`)
Configuration files are stored in:
`$XDG_CONFIG_HOME/zig-waybar-contrib/<module>.zon` or `~/.config/zig-waybar-contrib/<module>.zon`.
- Parsed strictly using `std.zon.parse.fromSlice`.
- An `ArenaAllocator` manages string allocations from `.zon`.
- Unknown fields are safely ignored (`ignore_unknown_fields = true`).
- If a config file does not exist or has invalid syntax, `Config.load(...)` cleanly falls back to default values defined directly on the `ModuleConfig` struct.

### 4.3. Streaming JSON Writer (`utils.Json`)
- Avoids full AST serialization overhead.
- Serializes keys directly to the stream.
- Supports control character and unicode escaping (`\n`, `\t`, `\u0000`...).
- Manages Waybar CSS classes (`setClass("warning")` or `setClasses(&[_][]const u8{"warn", "custom"})`).

### 4.4. Template Replacement Engine (`utils.Replacer`)
- Parses `{placeholder:specifier}` formats.
- Supports precision specifiers for floats (e.g. `{frequency:2}` formats with 2 decimal places).
- Supports unit appending (e.g. `{val:unit}` or literal suffix `{val:'%'}`).
- Supports escaping (`{{` and `}}`).
- Built-in global placeholders: `{dot}` (`•`), `{sep}` (`|`), `{nl}` (`\n`).

### 4.5. D-Bus Integration via `plume`
For event-driven modules that interact with Linux system services (PipeWire/PulseAudio, Bluetooth BlueZ, MPRIS media players), the repository depends on the `plume` Zig D-Bus library. This allows native binary D-Bus communication without shelling out to `dbus-send` or `playerctl`.

---

## 5. Waybar Protocol Specification

The Waybar custom JSON module protocol expects each JSON line emitted on `stdout` to conform to:

| Field | Type | Description |
| :--- | :--- | :--- |
| `text` | string | Text displayed in the Waybar bar. |
| `alt` | string | Alternative text displayed based on state or clicks. |
| `tooltip` | string | Multiline text displayed when hovering the cursor over the module. |
| `class` | string or string array | CSS classes applied to the module for styling (e.g., `"warning"`, `"critical"`). |
| `percentage` | integer | Numeric percentage value (0-100) often used by Waybar for progress bar CSS. |
