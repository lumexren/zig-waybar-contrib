# Creating a New Waybar Module

This guide provides a comprehensive step-by-step tutorial for implementing a new Waybar module in `zig-waybar-contrib`.

---

## Overview of Steps

1. **Implement the Sysinfo Collector:** Create `src/sysinfo/<module>/` to extract hardware/OS metrics.
2. **Expose in Sysinfo Root:** Register the collector in `src/sysinfo/root.zig`.
3. **Write the Module Executable:** Implement `src/modules/<module>.zig`.
4. **Register in `build.zig`:** Add the module to the build system.
5. **Add Tests:** Write unit tests for metric gathering.
6. **Update Documentation:** Add user configuration options to `MODULES.md`.

---

## Step 1: Implement the Sysinfo Collector

Create a new directory under `src/sysinfo/<module>/`:

```
src/sysinfo/temperature/
├── TemperatureError.zig
├── TemperatureInfo.zig
└── root.zig
```

### 1.1 Error Set (`TemperatureError.zig`)
```zig
// SPDX-License-Identifier: GPL-3.0-only
pub const TemperatureError = error{
    SensorNotFound,
    InvalidReading,
    ReadFailed,
};
```

### 1.2 Data Structure (`TemperatureInfo.zig`)
```zig
// SPDX-License-Identifier: GPL-3.0-only
pub const TemperatureInfo = struct {
    celsius: f64 = 0.0,
    fahrenheit: f64 = 0.0,
    sensor_name: []const u8 = "cpu",
};
```

### 1.3 Collector Root (`src/sysinfo/temperature/root.zig`)
```zig
// SPDX-License-Identifier: GPL-3.0-only
const Temperature = @This();

pub const TemperatureError = @import("TemperatureError.zig").TemperatureError;
pub const TemperatureInfo = @import("TemperatureInfo.zig").TemperatureInfo;

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

io: Io,
allocator: Allocator,
info: TemperatureInfo = .{},

pub fn init(io: Io, allocator: Allocator) Temperature {
    return .{
        .io = io,
        .allocator = allocator,
    };
}

pub fn deinit(this: *Temperature) void {
    _ = this;
}

pub fn update(this: *Temperature) !void {
    // Read from /sys/class/thermal or /sys/class/hwmon into stack buffer
    // Calculate celsius and fahrenheit values into this.info
}
```

---

## Step 2: Expose in `src/sysinfo/root.zig`

Open `src/sysinfo/root.zig` and export your new collector:

```zig
pub const Temperature = @import("temperature/root.zig");

test {
    ...
    _ = @import("temperature/root.zig");
}
```

---

## Step 3: Implement the Module Executable

Create `src/modules/<module>.zig`:

```zig
// SPDX-License-Identifier: GPL-3.0-only
const Temperature = @import("sysinfo").Temperature;

const std = @import("std");
const utils = @import("utils");
const Module = utils.Module;
const process = std.process;

pub const ModuleConfig = struct {
    update_interval: i64 = 2,
    warning_threshold: ?f64 = 75.0,
    critical_threshold: ?f64 = 90.0,
    icon: []const u8 = "",
    text: []const u8 = "{icon}  {temp:1:'°C'}",
    tooltip: []const u8 = "Sensor: {sensor}{nl}Temp: {temp:1:'°C'} ({temp_f:1:'°F'})",
};

pub fn main(init: process.Init) !void {
    // 1. Initialize Module harness (handles stdout buffering, ZON loading,
    //    Watcher signalfd setup, Json, and Replacer lifecycle)
    var mod = try Module(ModuleConfig).init(init, "temperature");
    defer mod.deinit();

    var temp: Temperature = .init(init.io, init.gpa, null);
    defer temp.deinit();

    // 2. Loop with mod.tick() (handles intervals, instant SIGUSR1 wakeups,
    //    resetting builders, and registering common placeholders)
    while (try mod.tick()) {
        try temp.update();

        // 3. Ergonomically bind template keys
        try mod.put("sensor", temp.info.sensor_name);
        try mod.put("temp", temp.info.celsius);
        try mod.put("temp_f", temp.info.fahrenheit);

        // 4. Render templates, evaluate thresholds (critical/warning/normal),
        //    emit JSON to stdout, and flush
        try mod.render(.{
            .percentage = temp.info.celsius,
        });
    }
}
```

---

## Step 4: Register in `build.zig`

Open `build.zig` and add your module entry to the `modules` array:

```zig
const modules = [_]ModuleConfig{
    ...
    .{ .name = "temperature", .path = "src/modules/temperature.zig" },
};
```
*(If the module requires linking libc or C bindings, set `.libc = true`)*.

---

## Step 5: Test and Verify

1. **Verify compilation:**
   ```bash
   zig build
   ```
2. **Run tests:**
   ```bash
   zig build test
   ```
3. **Execute binary manually:**
   ```bash
   ./zig-out/bin/temperature
   ```
   *Expected output:* A JSON line like `{"text":"  42.5°C","tooltip":"Sensor: cpu\nTemp: 42.5°C (108.5°F)","percentage":42,"class":"normal"}`.
4. **Test signal wakeup:**
   In another terminal, run `pkill -SIGUSR1 temperature`. Observe that the module updates immediately without waiting for `update_interval`.
5. **Format code:**
   ```bash
   zig fmt .
   ```

---

## Step 6: Update `MODULES.md`

Add a section to `MODULES.md` describing:
- Configuration path (`~/.config/zig-waybar-contrib/<module>.zon`).
- Default `.zon` structure.
- Available placeholders in table format.
