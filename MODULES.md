# Modules

### **Backlight**

Controls backlight brightness.

- **Signal:** `10`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/backlight.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {percentage}%",
    // Custom tooltip format (default shown)
    .tooltip = "Brightness: {percentage}%{nl}Device: {name}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder        | Description                          |
| :----------------- | :----------------------------------- |
| `{icon}`           | Module icon                          |
| `{percentage}`     | Current brightness percentage        |
| `{brightness}`     | Current brightness value             |
| `{max_brightness}` | Maximum brightness value             |
| `{name}`           | Device name                          |

---

### **Battery**

Monitors battery status and percentage.

- **Signal:** `11`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/battery.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 5,
    // Module icon
    .icon = "",
    .icon_charging = "",
    .icon_full = "",
    // Custom text format (default shown)
    .text = "{icon}  {percentage}%",
    // Custom tooltip format (default shown)
    .tooltip = "Battery: {state}{nl}Time remaining: {time_remaining}{nl}Model: {model}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder       | Description                          |
| :---------------- | :----------------------------------- |
| `{icon}`          | Battery icon (charging/full/normal)  |
| `{percentage}`    | Battery percentage                   |
| `{state}`         | Battery state (e.g., Charging)       |
| `{time_remaining}`| Estimated time remaining             |
| `{time_to_empty}` | Seconds until empty                  |
| `{time_to_full}`  | Seconds until fully charged          |
| `{model}`         | Battery model name                   |
| `{vendor}`        | Battery vendor name                  |
| `{voltage}`       | Current voltage                      |
| `{energy}`        | Current energy                       |
| `{energy_rate}`   | Current energy rate                  |

---

### **Bluetooth**

Monitors bluetooth adapter state and connected devices.

- **Signal:** `12`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/bluetooth.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 5,
    // Icons
    .icon_on = "",
    .icon_off = "",
    // Custom text format (default shown)
    .text = "{icon}  {device_count}",
    // Custom tooltip format (default shown)
    .tooltip = "Adapter: {adapter_name}{nl}Power: {adapter_powered}{nl}Connected: {device_count} devices{nl}{devices}",
    // Format for each device in the list
    .device_format = "{device_alias}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder            | Description                          |
| :--------------------- | :----------------------------------- |
| `{icon}`               | Bluetooth status icon                |
| `{adapter_name}`       | Name of the adapter                  |
| `{adapter_powered}`    | Power state (true/false)             |
| `{adapter_discoverable}`| Discoverable state (true/false)     |
| `{device_count}`       | Number of connected devices          |
| `{devices}`            | List of connected devices            |

**Device List Format (`device_format`):**

The `device_format` string is used to format each entry in the `{devices}` list. It supports:

| Placeholder         | Description                          |
| :------------------ | :----------------------------------- |
| `{device_name}`     | Device name                          |
| `{device_alias}`    | Device alias                         |
| `{device_connected}`| Connection state (true/false)        |
| `{device_battery}`  | Device battery percentage (if avail) |

---

### **CPU**

Displays per-core CPU usage and frequency information.

- **Signal:** `13`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/cpu.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Start core index from 1 instead of 0
    .one_indexed = false,
    // Custom text format (default shown)
    .text = "{icon}  {usage_percentage}% {dot} {frequency:2}{frequency_unit}",
    // Custom tooltip format (default shown)
    .tooltip = "Core {core_index}: {core_usage_percentage}% {dot} {core_frequency:2}{core_frequency_unit}",
}
```

**Customization:**
The `text` and `tooltip` options support the following placeholders:

| Placeholder            | Description                            |
| :--------------------- | :------------------------------------- |
| `{icon}`               | Module icon                            |
| `{usage_percentage}`   | Average CPU usage percentage           |
| `{frequency}`          | Maximum current frequency across cores |
| `{frequency_unit}`     | Frequency unit (e.g., GHz)             |
| `{frequency_min}`      | Global minimum frequency (cpufreq)     |
| `{frequency_min_unit}` | Unit for min frequency                 |
| `{frequency_max}`      | Global maximum frequency (cpufreq)     |
| `{frequency_max_unit}` | Unit for max frequency                 |
| `{core_count}`         | Total number of CPU cores              |

**Tooltip:**

| Placeholder                 | Description                          |
| :-------------------------- | :----------------------------------- |
| `{core_index}`              | Index of the current core            |
| `{core_usage_percentage}`   | Usage percentage of the current core |
| `{core_frequency}`          | Current frequency of the core        |
| `{core_frequency_unit}`     | Frequency unit for the current core  |
| `{core_frequency_min}`      | Minimum frequency of the core        |
| `{core_frequency_min_unit}` | Unit for core min frequency          |
| `{core_frequency_max}`      | Maximum frequency of the core        |
| `{core_frequency_max_unit}` | Unit for core max frequency          |

---

### **Disk**

Monitors disk usage and space statistics.

- **Signal:** `14`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/disk.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 30,
    // Path to monitor (default: root filesystem)
    .path = "/",
    // Show all mounted filesystems in tooltip
    .show_all_mounts = false,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {percentage_used}% {dot} {used:.2}",
    // Custom tooltip format (default shown)
    .tooltip = "Total {dot} {total:.2}{nl}Free {dot} {free:.2}{nl}Used {dot} {used:.2}",
    // Tooltip format for each mount (when show_all_mounts = true)
    .mount_tooltip = "{mount_point}: {percentage_used}% ({free:.2} free)",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder              | Description                 |
| :----------------------- | :-------------------------- |
| `{icon}`                 | Module icon                 |
| `{path}`                 | Monitored path              |
| `{total}`                | Total disk space            |
| `{used}`                 | Used disk space             |
| `{free}`                 | Free disk space             |
| `{percentage_used}`      | Usage percentage            |
| `{percentage_free}`      | Free percentage             |
| `{inodes_total}`         | Total inodes                |
| `{inodes_used}`          | Used inodes                 |
| `{inodes_free}`          | Free inodes                 |
| `{inodes_percentage_used}` | Inode usage percentage    |

**Mount Tooltip (when `show_all_mounts = true`):**
| Placeholder        | Description                    |
| :----------------- | :----------------------------- |
| `{device}`         | Device path (e.g., `/dev/sda1`)|
| `{mount_point}`    | Mount point path               |
| `{fs_type}`        | Filesystem type                |

---

### **Fan**

Monitors fan speeds.

- **Signal:** `15`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/fan.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 5,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {total_fans}",
    // Custom tooltip format (default shown)
    .tooltip = "{name}: {speed} RPM",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder    | Description                   |
| :------------- | :---------------------------- |
| `{icon}`       | Module icon                   |
| `{total_fans}` | Total number of fans detected |

**Tooltip:**
| Placeholder | Description      |
| :---------- | :--------------- |
| `{name}`    | Fan label/name   |
| `{speed}`   | Fan speed in RPM |

---

### **GPU**

> [!NOTE]
> This module requires `amdsmi` for AMD GPUs or `cuda` for NVIDIA GPUs.<br>
> Intel GPUs are not supported.
>
> If no GPU library is found, the module will not work.

Monitors GPU usage, temperature, and VRAM statistics.

- **Signal:** `16`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/gpu.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {usage_percentage}% {dot} {temperature}°C",
    // Custom tooltip format (default shown)
    .tooltip = "PWM {dot} {pwm_percentage}%{nl}VRAM Total {dot} {vram_total:.0}{nl}VRAM Free {dot} {vram_free:.2}{nl}VRAM Usage {dot} {vram_usage:.2}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder          | Description           |
| :------------------- | :-------------------- |
| `{icon}`             | Module icon           |
| `{usage_percentage}` | GPU usage percentage  |
| `{temperature}`      | GPU temperature (°C)  |
| `{pwm_percentage}`   | Fan speed PWM (%)     |
| `{vram_total}`       | Total VRAM size       |
| `{vram_usage}`       | Used VRAM size        |
| `{vram_free}`        | Free VRAM size        |

---

### **Memory**

Reports RAM usage and memory statistics.

- **Signal:** `17`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/memory.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {percentage}% {dot} {total_usage:.2}",
    // Custom tooltip format (default shown)
    .tooltip = "Physical Memory{nl}Total {dot} {physical_total:.2}{nl}Used {dot} {physical_used:.2}{nl}Free {dot} {physical_free:.2}{nl}Available {dot} {physical_available:.2}{nl}Shared {dot} {physical_shared:.2}{nl}Buffers {dot} {physical_buffers:.2}{nl}Cached {dot} {physical_cached:.2}{nl}{nl}Swap Memory{nl}Total {dot} {swap_total:.2}{nl}Used {dot} {swap_used:.2}{nl}Free {dot} {swap_free:.2}{nl}Cached {dot} {swap_cached:.2}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder                     | Description                                          |
| :------------------------------ | :--------------------------------------------------- |
| `{icon}`                        | Module icon                                          |
| `{percentage}`                  | Memory usage percentage                              |
| `{total_usage}`                 | Total memory usage (physical + swap)                 |
| `{physical_total}`              | Total physical RAM (MemTotal)                        |
| `{physical_free}`               | Free physical RAM (MemFree)                          |
| `{physical_available}`          | Available physical RAM (MemAvailable)                |
| `{physical_used}`               | Used physical RAM                                    |
| `{physical_buffers}`            | Buffers (Buffers)                                    |
| `{physical_cached}`             | Cached (Cached)                                      |
| `{physical_shared}`             | Shared memory (Shmem)                                |
| `{physical_active}`             | Active memory                                        |
| `{physical_inactive}`           | Inactive memory                                      |
| `{physical_active_anon}`        | Active anonymous memory                              |
| `{physical_inactive_anon}`      | Inactive anonymous memory                            |
| `{physical_active_file}`        | Active file-backed memory                            |
| `{physical_inactive_file}`      | Inactive file-backed memory                          |
| `{physical_anon_pages}`         | Anonymous pages                                      |
| `{physical_mapped}`             | Mapped memory                                        |
| `{physical_slab}`               | Slab memory                                          |
| `{physical_slab_reclaimable}`   | Reclaimable slab memory                              |
| `{physical_slab_unreclaimable}` | Unreclaimable slab memory                            |
| `{physical_kernel_reclaimable}` | Kernel reclaimable memory                            |
| `{physical_kernel_stack}`       | Kernel stack usage                                   |
| `{physical_page_tables}`        | Page tables size                                     |
| `{physical_sec_page_tables}`    | Secondary page tables size                           |
| `{physical_percpu}`             | Per-CPU memory                                       |
| `{physical_dirty}`              | Dirty pages                                          |
| `{physical_writeback}`          | Writeback memory                                     |
| `{physical_writeback_tmp}`      | Temporary writeback memory                           |
| `{physical_unevictable}`        | Unevictable pages                                    |
| `{physical_mlocked}`            | Mlocked pages                                        |
| `{physical_anon_huge_pages}`    | Anonymous huge pages                                 |
| `{physical_file_huge_pages}`    | File-backed huge pages                               |
| `{physical_file_pmd_mapped}`    | File-backed PMD mapped                               |
| `{physical_shmem_huge_pages}`   | Shared huge pages                                    |
| `{physical_shmem_pmd_mapped}`   | Shared PMD mapped                                    |
| `{physical_hugetlb}`            | Hugetlb memory                                       |
| `{physical_hugepages_size}`     | Hugepages size                                       |
| `{physical_direct_map_4k}`      | Direct map 4k                                        |
| `{physical_direct_map_2m}`      | Direct map 2M                                        |
| `{physical_direct_map_1g}`      | Direct map 1G                                        |
| `{physical_vmalloc_total}`      | Vmalloc total                                        |
| `{physical_vmalloc_used}`       | Vmalloc used                                         |
| `{physical_vmalloc_chunk}`      | Vmalloc chunk                                        |
| `{physical_hardware_corrupted}` | Hardware corrupted memory                            |
| `{physical_bounce}`             | Bounce buffers                                       |
| `{physical_nfs_unstable}`       | NFS unstable pages                                   |
| `{physical_cma_total}`          | CMA total                                            |
| `{physical_cma_free}`           | CMA free                                             |
| `{physical_unaccepted}`         | Unaccepted memory                                    |
| `{physical_balloon}`            | Balloon memory                                       |
| `{swap_total}`                  | Total swap memory (SwapTotal)                        |
| `{swap_free}`                   | Free swap memory (SwapFree)                          |
| `{swap_used}`                   | Used swap memory                                     |
| `{swap_cached}`                 | Cached swap memory (SwapCached)                      |
| `{swap_zswap}`                  | Zswap memory                                         |
| `{swap_zswapped}`               | Zswapped memory                                      |
| `{swap_commit_limit}`           | Commit limit                                         |
| `{swap_committed_as}`           | Committed AS                                         |

---

### **MPRIS**

Displays media player information using the MPRIS2 standard.

- **Signal:** `18`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/mpris.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Status icons
    .icon_playing = "",
    .icon_paused = "",
    .icon_stopped = "",
    // Custom text format (default shown)
    .text = "{icon}  {title} {dot} {artist}",
    // Max length of text
    .text_max_length = 256,
    // Custom tooltip format (default shown)
    .tooltip = "{player_name}: {status}{nl}{title} - {artist}{nl}Album: {album}{nl}{position} / {length}",
    // Text to show when no player is found
    .no_player_text = "No player",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder         | Description                            |
| :------------------ | :------------------------------------- |
| `{icon}`            | Status icon or generic icon            |
| `{player_name}`     | Name of the active player              |
| `{identity}`        | Unique identity of the player          |
| `{status}`          | Player status (Playing, Paused, etc.)  |
| `{loop_status}`     | Loop status                            |
| `{shuffle}`         | Shuffle status (true/false)            |
| `{volume}`          | Volume percentage (0-100)              |
| `{title}`           | Track title                            |
| `{artist}`          | Track artist                           |
| `{album}`           | Track album                            |
| `{art_url}`         | Album art URL                          |
| `{position}`        | Formatted track position (MM:SS)       |
| `{position_us}`     | Track position in microseconds         |
| `{length}`          | Formatted track length (MM:SS)         |
| `{length_us}`       | Track length in microseconds           |
| `{can_control}`     | Player control capability              |
| `{can_go_next}`     | Can skip to next track                 |
| `{can_go_previous}` | Can skip to previous track             |
| `{can_play}`        | Can play                               |
| `{can_pause}`       | Can pause                              |
| `{can_seek}`        | Can seek                               |

---

### **Network**

Monitors network traffic and speed.

- **Signal:** `19`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/network.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {total_speed:^1}",
    // Custom tooltip format (default shown)
    .tooltip = "Interface {dot} {interface}{nl}Gateway {dot} {gateway}{nl}Local IP {dot} {local_ip}{nl}{nl}Download {dot} {download_speed:^1}{nl}Upload {dot} {upload_speed:^1}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder        | Description                          |
| :----------------- | :----------------------------------- |
| `{icon}`           | Module icon                          |
| `{interface}`      | Network interface name               |
| `{gateway}`        | Gateway IP address                   |
| `{local_ip}`       | Local IP address                     |
| `{download_speed}` | Download speed (supports `^N` fmt)   |
| `{upload_speed}`   | Upload speed (supports `^N` fmt)     |
| `{total_speed}`    | Total speed (supports `^N` fmt)      |

---

### **Ping**

Measures network latency to a configurable host using ICMP.

- **Signal:** `20`
- **Platforms:** Any Linux

**Configuration (`~/.config/zig-waybar-contrib/ping.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 1,
    // Target domain to ping
    .target_domain = "google.com",
    // Interval to refresh the resolved IP address (seconds)
    .target_domain_ip_update_interval = 200,
    // Module icon
    .icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {latency}ms",
    // Custom tooltip format (default shown)
    .tooltip = "Min: {min_latency}ms {dot} Avg: {avg_latency}ms {dot} Max: {max_latency}ms{nl}Domain: {target}{nl}IP: {ip} {dot} {next_ip_update}s",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder        | Description                          |
| :----------------- | :----------------------------------- |
| `{icon}`           | Module icon                          |
| `{target}`         | Target domain                        |
| `{ip}`             | Resolved IP address of the target    |
| `{next_ip_update}` | Seconds until next IP resolution     |
| `{latency}`        | Latency in milliseconds (or "N/A")   |
| `{min_latency}`    | Minimum latency in milliseconds      |
| `{avg_latency}`    | Average latency in milliseconds      |
| `{max_latency}`    | Maximum latency in milliseconds      |

---

### **Updates**

Tracks available system package updates.

- **Signal:** `21`
- **Platforms:** Arch Linux, Debian, Fedora, OpenSUSE, Void Linux
- **Managers:** pacman, apt, dnf, zypper, xbps

**Configuration (`~/.config/zig-waybar-contrib/updates.zon`):**
```zig
.{
    // Check interval in seconds
    .update_interval = 200,
    // Package manager override (optional)
    // .manager = "pacman",
    // Module icon
    .icon = "",
    // Error icon
    .error_icon = "",
    // Custom text format (default shown)
    .text = "{icon}  {total_updates}",
    // Custom tooltip format (default shown)
    .tooltip = "{package_name}: {new_version}",
}
```

**Customization:**

The `text` and `tooltip` options support the following placeholders:

| Placeholder       | Description                            |
| :---------------- | :------------------------------------- |
| `{icon}`          | Module icon                            |
| `{total_updates}` | Total number of available updates      |
| `{manager}`       | Name of the package manager being used |

**Tooltip:**
| Placeholder      | Description                   |
| :--------------- | :---------------------------- |
| `{package_name}` | Name of the package to update |
| `{new_version}`  | New version number            |

---

### **Common Placeholders**

These placeholders are available in all modules:

| Placeholder           | Description          |
| :-------------------- | :------------------- |
| `{nl}`, `{newline}`   | Newline character    |
| `{tab}`               | Tab character        |
| `{dot}`               | Middle dot (·)       |
| `{pipe}`              | Pipe character (\|)  |

---

### **Replacer Formatters**

The configuration system supports format specifiers, raw literals, and multi-variable chaining to control exactly how values are displayed.

| Specifier | Applies To | Description | Example |
| :--- | :--- | :--- | :--- |
| `*N` | Strings | Repeats the string value exactly N times | `{dot*5}` → `·····` |
| `N` | Integers | Zero-pads integers to width N | `{usage:2}` → `05` |
| `N` | Floats | Decimal precision N | `{usage:2}` → `12.34` |
| `.N` | Integers | Formats bytes to human-readable string with N decimal precision (Binary) | `{vram_usage:.2}` → `1.50 GiB` |
| `^N` | Floats | Formats network speed to human-readable string with N decimal precision (Decimal) | `{total_speed:^1}` → `2.5 MB/s` |
| `'X'` | Literals | Appends the raw string text `X` directly to the output sequence | `{usage:'%'}` → `0%` |

---

### **Advanced Variable Chaining**

Instead of writing multiple standalone placeholders back-to-back, you can chain multiple global keys, formatters, and raw text literals together inside a single wrapper block separated by colons (`:`). The engine evaluates and joins them sequentially from left to right.

* **Global Value Chaining:** Fetch and append other global variables without closing the tag.
  * `{frequency:frequency_unit}` → `4200MHz`
* **Literal Suffixing:** Seamlessly attach units or structural symbols using single quotes.
  * `{frequency:2:'Hz'}` → `4200Hz`
  * `{cpu_brand:' | ':cpu_usage:'%'}` → `AMD | 85%`