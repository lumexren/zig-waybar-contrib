# Project Structure

This document provides a detailed map of the `zig-waybar-contrib` directory structure, files, and module relationships.

---

## 🌳 Directory Map

```
zig-waybar-contrib/
├── AGENTS/                     # AI Agent knowledge base & developer guides
│   ├── README.md               # Main entrypoint & table of contents
│   ├── ARCHITECTURE.md         # Pipeline, execution model & Waybar protocol
│   ├── PROJECT_STRUCTURE.md    # Codebase directory layout & role reference
│   ├── BUILD_AND_TEST.md       # Toolchain, build steps, testing & benchmarking
│   ├── CONVENTIONS.md          # Coding style, Zig 0.18 idioms & memory rules
│   ├── SUBSYSTEMS.md           # Deep dives into Config, Json, Replacer, Watcher
│   └── CREATING_MODULES.md     # How to implement a new Waybar module
│
├── aur/                        # Arch User Repository (AUR) packaging files
│   ├── zig-waybar-contrib/     # Stable release PKGBUILD
│   ├── zig-waybar-contrib-beta-bin/ # Beta binary package PKGBUILD
│   └── release.sh              # Release helper script for AUR
│
├── benchmark/                  # Performance and allocation benchmarks
│   ├── root.zig                # Benchmark CLI entrypoint (`zig build bench`)
│   ├── runner.zig              # Formatting, timing & results printer
│   ├── Result.zig              # Benchmark result structures
│   ├── TrackingAllocator.zig   # Allocator tracking memory usage & peak bytes
│   └── benchmarks/
│       ├── json.zig            # JSON serialization throughput benchmarks
│       ├── replacer.zig        # Replacer template interpolation benchmarks
│       └── sysinfo.zig         # Hardware reader latency & allocation benchmarks
│
├── src/                        # Core source code
│   ├── bindings/               # C ABI and system bindings
│   │   ├── root.zig            # Module root exporting nvml, amdsmi, statvfs
│   │   ├── amdsmi.zig          # AMD SMI (ROCm) C header bindings
│   │   ├── nvml.zig            # NVIDIA NVML (CUDA) C header bindings
│   │   └── statvfs.zig         # POSIX statvfs C wrapper for filesystem sizing
│   │
│   ├── modules/                # Executable entrypoints for each Waybar module
│   │   ├── backlight.zig       # Brightness monitor
│   │   ├── battery.zig         # Battery level and charging status (UPower/sysfs)
│   │   ├── bluetooth.zig       # Bluetooth status & device counts (BlueZ D-Bus)
│   │   ├── cpu.zig             # Per-core and aggregate CPU usage & frequency
│   │   ├── disk.zig            # Mounted filesystem usage & storage metrics
│   │   ├── fan.zig             # Hardware fan RPM monitor
│   │   ├── gpu.zig             # GPU stats (NVIDIA NVML & AMD SMI)
│   │   ├── memory.zig          # RAM and Swap statistics
│   │   ├── mpris.zig           # Media player metadata & playback status
│   │   ├── network.zig         # Network interfaces, IP, traffic rates
│   │   ├── ping.zig            # ICMP latency / connectivity monitor
│   │   ├── pipewire.zig        # PipeWire/PulseAudio volume & mute status
│   │   └── updates.zig         # Available system updates (pacman, apt, etc.)
│   │
│   ├── sysinfo/                # System metric readers and domain logic
│   │   ├── root.zig            # Root aggregator of all sysinfo collectors
│   │   ├── backlight/          # Reads `/sys/class/backlight`
│   │   ├── battery/            # Reads sysfs battery data or UPower
│   │   ├── bluetooth/          # Interacts with BlueZ via plume D-Bus
│   │   ├── cpu/                # Parses `/proc/stat` & `/sys/devices/system/cpu`
│   │   ├── disk/               # Parses `/proc/mounts` and queries `statvfs`
│   │   ├── fan/                # Reads `/sys/class/hwmon` fan inputs
│   │   ├── gpu/                # Abstraction layer for NVML & AMD SMI
│   │   ├── memory/             # Parses `/proc/meminfo`
│   │   ├── mpris/              # Interacts with org.mpris.MediaPlayer2 via plume
│   │   ├── network/            # Parses `/proc/net/dev`, `/proc/net/route`, ioctls
│   │   ├── pipewire/           # Connects to PulseAudio/PipeWire D-Bus interface
│   │   └── updates/            # Queries package managers (pacman, checkupdates, etc.)
│   │
│   └── utils/                  # Reusable utility libraries
│       ├── root.zig            # Root exporting Config, Json, Replacer, Process, Watcher
│       ├── config/             # ZON configuration file loader with ArenaAllocator
│       ├── json/               # Fast, minimal streaming JSON writer
│       ├── process/            # Process iterator (`/proc`), child process execution
│       ├── replacer/           # String template placeholder formatting engine
│       └── watcher/            # Linux signalfd listener for SIGUSR1 / SIGUSR2
│
├── build.zig                   # Zig 0.18 build script (executables, modules, steps)
├── build.zig.zon               # Package dependencies (e.g. plume D-Bus library)
├── config.waybar.jsonc         # Sample Waybar configuration integrating all modules
├── CONTRIBUTING.md             # Contribution guide and pull request instructions
├── LICENSE                     # GNU General Public License v3.0 text
├── MODULES.md                  # Comprehensive user-facing module configuration guide
├── README.md                   # Project overview, quickstart, AUR instructions
└── .zigversion                 # Pin for current supported Zig version (0.18.0-dev.4)
```

---

## 📦 Key Component Taxonomy

### 1. `src/modules/`
Each file in `src/modules/<name>.zig` defines a standalone executable.
- Has a `pub fn main(init: process.Init) !void` entrypoint.
- Declares a `pub const ModuleConfig = struct { ... };` with default values.
- Reads configuration from `~/.config/zig-waybar-contrib/<name>.zon`.
- Coordinates data retrieval from `src/sysinfo/`, populates `utils.Replacer`, and streams formatted lines with `utils.Json`.

### 2. `src/sysinfo/`
Domain-specific modules that isolate OS interactions:
- Each collector lives in its own subdirectory (e.g., `src/sysinfo/cpu/`).
- Exposes typed structs representing hardware state (e.g., `CPUInfo`, `NetworkStats`).
- Defines specific error sets (e.g., `CPUError.zig`, `NetworkError.zig`).
- Employs zero or minimal allocations during periodic `update()` calls.

### 3. `src/utils/`
Shared foundational infrastructure:
- **`Config`**: Resolves `$XDG_CONFIG_HOME/zig-waybar-contrib/<name>.zon` and parses typed Zig data.
- **`Json`**: Lightweight serializer adhering to Waybar's JSON fields (`text`, `tooltip`, `percentage`, `class`).
- **`Replacer`**: High-performance placeholder substitution engine with float formatting and unit suffixes.
- **`Watcher`**: Blocks signals `SIGUSR1`/`SIGUSR2` and listens via Linux `signalfd`, enabling instantaneous wakeups.
- **`Process`**: High-level process search and execution helpers for external utilities.

### 4. `src/bindings/`
Low-level C bindings:
- **`nvml.zig`**: NVIDIA Management Library bindings (GPU metrics, VRAM, temps).
- **`amdsmi.zig`**: AMD SMI library bindings for Radeon GPUs.
- **`statvfs.zig`**: Filesystem space metadata querying.
