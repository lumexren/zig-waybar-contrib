# Build, Test & Benchmark Guide

This document covers compiling, testing, benchmarking, and packaging `zig-waybar-contrib`.

---

## 🛠️ Toolchain Requirements

- **Zig Version:** Requires **`0.18.0-dev`** (see [.zigversion](../.zigversion) and [build.zig.zon](../build.zig.zon)).
- The codebase uses the modern **`std.Io`** interface introduced in Zig 0.18. Attempting to build with Zig 0.17 or earlier will result in compilation errors.

### Managing Zig with `zvm` (Zig Version Manager)
If you have multiple Zig versions installed via `zvm`:
```bash
# Verify installed versions
zvm ls

# Switch to master (or run directly from zvm's master path)
zvm use master
# Or invoke directly:
/home/eren/.local/share/zvm/master/zig build
```

---

## 🏗️ Build Commands

### Standard Build (Debug)
Compiles all 13 module binaries into `zig-out/bin/`:
```bash
zig build
```

### Production / Release Builds
Modules are typically installed with `-Doptimize=small` for minimum footprint or `-Doptimize=fast` for maximum throughput:

```bash
# Small binaries (recommended for Waybar):
# Automatically enables thin LTO and binary stripping
zig build -Doptimize=small

# Fast execution:
# Automatically enables full LTO and binary stripping
zig build -Doptimize=fast
```

### GPU Driver Paths
By default, the build script detects whether AMD SMI and NVIDIA NVML headers and shared libraries exist. You can provide explicit paths if installed non-standardly:
```bash
zig build -Drocm-path=/opt/rocm -Dcuda-path=/opt/cuda/targets/x86_64-linux
```

---

## 🧪 Running Tests

The test suite validates both `src/utils/` and `src/sysinfo/`:

```bash
# Run all unit tests
zig build test

# Run tests with summary
zig build test --summary all
```

### Test Organization
- **`src/utils/root.zig`**: Runs unit tests for JSON formatting, escaping, template replacements, signal watcher, and process utilities.
- **`src/sysinfo/root.zig`**: Runs tests for metric calculations, string formatters, and hardware reader logic.

---

## ⚡ Running Benchmarks

`zig-waybar-contrib` has a built-in benchmarking suite that tests execution latency and heap allocations using `TrackingAllocator`.

```bash
# Run all benchmarks
zig build bench

# Run specific benchmark suites using filters:
zig build bench -- json        # JSON serialization throughput
zig build bench -- replacer    # Template placeholder interpolation
zig build bench -- sysinfo     # System metric collectors

# Benchmark help
zig build bench -- -h
```

### Benchmark Metric Outputs
Each benchmark reports:
- Iteration count
- Elapsed execution time
- Average execution time (µs / ns)
- Allocation count
- Total allocated bytes & peak memory usage

---

## 📦 Packaging & AUR Release

The repository contains files for the Arch User Repository in the `aur/` folder:
- `aur/zig-waybar-contrib/PKGBUILD`: Source-built package for Arch Linux.
- `aur/zig-waybar-contrib-beta-bin/PKGBUILD`: Pre-compiled binary package.
- `aur/release.sh`: Helper script to bump version, generate source tarballs, update checksums, and publish to AUR.
