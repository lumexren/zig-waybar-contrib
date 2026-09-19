![zig-waybar-contrib](https://img.shields.io/badge/zig--waybar--contrib-gray?style=for-the-badge&logo=zig&logoColor=orange) 
![License](https://img.shields.io/badge/License-GPL--3.0-orange?style=for-the-badge) 
![Stars](https://img.shields.io/gitea/stars/erenvly/zig-waybar-contrib?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=DAA520)
![Issues](https://img.shields.io/gitea/issues/open/erenvly/zig-waybar-contrib?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge)
![Last Commit](https://img.shields.io/gitea/last-commit/erenvly/zig-waybar-contrib?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=F7A41D)
<br>

**High-performance Waybar modules written in Zig for efficient system monitoring**

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Modules](#modules)
- [Installation](#installation)
- [Configuration](#configuration)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)

## Overview

`zig-waybar-contrib` is a collection of high-performance custom modules for [Waybar](https://github.com/Alexays/Waybar), built using [Zig](https://ziglang.org). Each module runs as a standalone binary that communicates with Waybar via JSON on stdout, giving you fine-grained control over update intervals, thresholds, and display formats.

## Features

- **Blazingly Fast** - Minimal startup time and runtime overhead with zero idle CPU polling
- **Memory Safe** - Leveraging Zig's safety features to prevent common crashes and leaks
- **Zero Dependencies** - Statically linked binaries that run anywhere without runtime interpreters
- **Deeply Configurable** - Simple, type-safe configuration using Zig Object Notation (`.zon`)
- **Rich Placeholders** - Per-module and global placeholders with format specifiers, chaining, and literals
- **Thresholds** - Configurable warning/critical thresholds for automatic CSS class switching

## Modules

| Module | Description |
|:-------|:------------|
| **CPU** | Per-core CPU usage and frequency |
| **Memory** | RAM usage and swap statistics |
| **Disk** | Disk usage with mount tooltip support |
| **Network** | Traffic speed and interface info |
| **Ping** | ICMP latency with min/avg/max |
| **Fan** | Fan speed monitoring |
| **GPU** | Usage, temperature, VRAM (AMD/NVIDIA) |
| **Bluetooth** | Adapter state and connected devices |
| **PipeWire** | Master volume and mute (event-driven) |
| **Backlight** | Backlight brightness |
| **Battery** | Battery status and time remaining |
| **MPRIS** | Media player information |
| **Updates** | Package updates (pacman/apt/dnf/zypper/xbps) |

See [MODULES](MODULES.md) for detailed documentation on each module.

## Installation

### Quick Installation (AUR)

Install the latest stable release from the [AUR](https://aur.archlinux.org/packages/zig-waybar-contrib).

```bash
# Using paru
paru -S zig-waybar-contrib

# Using yay
yay -S zig-waybar-contrib
```

### Manual Build

To build from source, you need [Zig](https://ziglang.org/download) installed (check `build.zig` for version requirements).

```bash
git clone https://codeberg.org/erenvly/zig-waybar-contrib.git
cd zig-waybar-contrib
zig build -Doptimize=small
```

Binaries will be available in `zig-out/bin/`.

> [!NOTE]
> To try the Nightly versions, follow the `Manual Build` section.
> To try the Beta versions, install the `zig-waybar-contrib-beta-bin` package from [AUR](https://aur.archlinux.org/packages/zig-waybar-contrib-beta-bin) (when available).

## Configuration

Add the modules to your Waybar configuration. Each module is a standalone executable that outputs JSON on stdout.

### Method 1: Include Config

```jsonc
{
  // Load module configurations from zig-waybar-contrib
  "include": [
    "/usr/share/zig-waybar-contrib/config.jsonc", // if installed from AUR
  ],

  "modules-right": [
    "custom/updates",
    "custom/memory",
    "custom/ping",
    "custom/cpu",
    "custom/fan"
  ]
}
```

### Method 2: Manual Definition

See the source code in `src/modules/` for the default configuration values and adapt them to your needs.

Each module reads its configuration from `~/.config/zig-waybar-contrib/<module>.zon`. See [MODULES](MODULES.md) for the full reference.

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md)

## Acknowledgments

- **Zig Team** - For creating an amazing systems programming language
- **Waybar Contributors** - For the excellent status bar that makes this possible
- **Community** - For feedback, bug reports, and contributions

---

<div align="center">

**Built with ❤️ by erenvly**

*Star ⭐ this repo if you find it useful!*<br>
*Join our [Fluxer](https://fluxer.gg/xnTFlhV0) for support and updates!*

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](./LICENSE) for details.

</div>