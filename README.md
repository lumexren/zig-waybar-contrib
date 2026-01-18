> [!IMPORTANT]
> I decided to split this project in two.<br>
> I will create a separate library to retrieve the information,<br>
> meaning this project will only use that library and carry out the function of writing the information to the waybar as json.<br>
> The reason I am doing this is because the current version is very limited in terms of future prospects, which really scares me.

![zig-waybar-contrib](https://img.shields.io/badge/zig--waybar--contrib-gray?style=for-the-badge&logo=zig&logoColor=orange) 
![License](https://img.shields.io/badge/License-GPL--3.0-orange?style=for-the-badge) 
![Stars](https://img.shields.io/gitea/stars/erffy/zig-waybar-contrib?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=DAA520)
![Issues](https://img.shields.io/github/issues/erffy/zig-waybar-contrib?style=for-the-badge)
![Last Commit](https://img.shields.io/gitea/last-commit/erffy/zig-waybar-contrib?gitea_url=https%3A%2F%2Fcodeberg.org&style=for-the-badge&color=F7A41D)

**High-performance Waybar modules written in Zig for efficient system monitoring**

### Overview

`zig-waybar-contrib` is a collection of lightweight, blazingly fast Waybar modules built with Zig. These modules are designed to provide accurate system monitoring with minimal resource usage, taking advantage of Zig's performance characteristics and memory safety.

**Key Features:**
- 🚀 **High Performance**: Native binaries with minimal overhead.
- 🛡️ **Memory Safe**: Built with Zig's safety features.
- 🧩 **Drop-in Replacement**: Compatible with Waybar's custom module interface.

### Modules

| Module      | Description                            |
|:------------|:---------------------------------------|
| **CPU**     | Displays per-core CPU usage            |
| **Fan**     | Monitors fan speeds                    |
| **GPU**     | Monitors GPU stats                     |
| **Memory**  | Reports RAM usage and statistics       |
| **Network** | Tracks network status                  |
| **Ping**    | Measures network latency               |
| **Updates** | Tracks system package updates          |

See [MODULES](MODULES.md) for detailed documentation on each module.

### Installation

![Repology](https://repology.org/badge/vertical-allrepos/zig-waybar-contrib.svg)
![Repology](https://repology.org/badge/vertical-allrepos/zig-waybar-contrib-beta-bin.svg)

#### Quick Installation (AUR)

You can easily install the latest version from the [AUR](https://aur.archlinux.org/packages/zig-waybar-contrib).

```bash
# Using paru
paru -S zig-waybar-contrib

# Using yay
yay -S zig-waybar-contrib
```

> [!NOTE]
> To try the beta versions, run `install.sh`.<br>
> On Arch Linux, you can alternatively install the `zig-waybar-contrib-beta-bin` package from the [AUR](https://aur.archlinux.org/packages/zig-waybar-contrib-beta-bin)

#### Script Installation

> [!NOTE]
> This script doesn't need root permissions.

The installation script automates cloning, building, and installing.

```bash
bash -c "$(curl -fsSL https://codeberg.org/erffy/zig-waybar-contrib/raw/branch/0.16-dev/install.sh)"
```

This script installs into your `$HOME` directory (`$HOME/.local/share/zig-waybar-contrib`) and places its binaries in `$HOME/.local/bin`.

#### Manual Build (From Source)

To build from source, you need [Zig](https://ziglang.org/download/) installed (check `build.zig` for version requirements).

```bash
git clone https://codeberg.org/erffy/zig-waybar-contrib.git
cd zig-waybar-contrib
zig build -Doptimize=ReleaseFast
```

> [!TIP]
> The build system automatically detects available libraries and package managers. If dependencies for `gpu` or `updates` modules are missing, those modules might be skipped.

Binaries will be available in `zig-out/bin/`.

### Configuration

Add the modules to your Waybar configuration. You can include the provided config file or define modules manually.

**Method 1: Include Config**

```jsonc
{
  // Load module configurations from zig-waybar-contrib
  "include": [
    "/usr/share/zig-waybar-contrib/config.jsonc", // if you installed from aur
    "~/.local/share/zig-waybar-contrib/config.waybar.jsonc" // if you installed with script
  ],

  "modules-right": [
    "custom/updates",
    "custom/gpu",
    "custom/memory",
    "custom/ping",
    "custom/cpu",
    "custom/network"
  ]
}
```

**Method 2: Manual Definition**

See [config.waybar.jsonc](config.waybar.jsonc) for the default configuration values.

### Contributing

See [CONTRIBUTING](CONTRIBUTING.md)

### Acknowledgments

- **Zig Team** - For creating an amazing systems programming language
- **Waybar Contributors** - For the excellent status bar that makes this possible
- **Community** - For feedback, bug reports, and contributions

---

<div align="center">

**Made with ❤️ by Me**

*Star ⭐ this repo if you find it useful!*

This project is licensed under the **GNU General Public License v3.0**. See [LICENSE](./LICENSE) for details.

</div>
