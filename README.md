# Mobile CPU Power Measurement Scripts

A collection of shell scripts and Python tools for measuring and analyzing per-core and per-cluster power consumption on mobile devices (Android smartphones).

## Overview

This repository contains automated measurement scripts for characterizing CPU power consumption across different core clusters (LITTLE, BIG, and PRIME) on mobile devices. The scripts implement CPU isolation techniques using cgroup cpusets to ensure accurate power measurements by shielding cores from system task interference.

## Supported Devices

- **Google Pixel 8 Pro** (9 cores: LITTLE 0-3, BIG 4-7, PRIME 8)
- **Samsung Galaxy A16** (8 cores: LITTLE 0-5, BIG 6-7)

## Features

- **Per-Cluster Power Measurement**: Isolated testing of LITTLE, BIG, and PRIME core clusters
- **CPU Shielding**: Uses cgroup cpusets to isolate cores from system tasks
- **Multi-Phase Testing**: 
  - Phase 0: Baseline (CPU0 only idle)
  - Phase 1: Cluster cores idle
  - Phase 2: Cluster cores stressed
- **Accurate CPU Affinity**: Explicit hexadecimal masks to avoid taskset errors
- **Comprehensive Logging**: CSV output with timestamps, power, temperature, frequency, and CPU usage data

## Prerequisites

### On the Mobile Device

- **Root access** (su)
- **Android Debug Bridge (adb)** connection
- Required binaries:
  - `stress-ng` (for CPU stress testing)
  - `taskset` (for CPU affinity)
  - `dumpsys` (for battery/temperature data)

### On the Host Machine

- Python 3.x (for analysis scripts)
- ADB installed and in PATH
- USB debugging enabled on device

## Usage

### 1. Push Script to Device

```bash
# For Google Pixel LITTLE cluster
adb push "mobile phone scripts/Google Pixel/Per cluster/g_little.sh" /data/local/tmp/

# For Samsung A16 BIG cluster
adb push "mobile phone scripts/Samsung A16/Per cluster/s_big.sh" /data/local/tmp/
```

### 2. Run Measurement

```bash
adb shell
su
sh /data/local/tmp/g_little.sh [duration_sec] [interval_s] [idle_gap_sec] [minmax]
```

**Parameters:**
- `duration_sec`: Duration of each phase in seconds (default: 60)
- `interval_s`: Sampling interval in seconds (default: 0.5)
- `idle_gap_sec`: Idle gap between phases in seconds (default: 0)
- `minmax`: Optional suffix for output file (e.g., "min" or "max")

**Example:**
```bash
# Run 600-second test with 0.5s sampling and 300s idle gap
sh /data/local/tmp/g_little.sh 600 0.5 300
```

### 3. Retrieve Results

```bash
# Pull CSV results from device
adb pull /data/local/tmp/little_core_power.csv ./csv_files/mobile_phone/Google\ Pixel/
```

## Key Measurement Considerations

1. **Thermal Stabilization**: Allow device to cool between measurements to avoid thermal throttling
2. **Background Apps**: Close all apps and disable unnecessary services before testing
3. **Screen State**: Scripts acquire wakelock to maintain consistent state during measurement
4. **CPU Governor**: Consider fixing CPU frequency governor to `performance` or `userspace` for consistent frequency
5. **Battery Level**: Maintain consistent battery level across tests (e.g., 50-80%)
6. **Airplane Mode**: Enable airplane mode to reduce background network activity

## License

This repository is for research and educational purposes.

