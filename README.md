# Mobile CPU Power Measurement Scripts

A collection of shell scripts and Python tools for measuring and analyzing per-core and per-cluster power consumption on ARM-based mobile devices and x86 workstations.

## Overview

This repository provides **interactive measurement scripts** that work on any device through runtime configuration. The scripts implement CPU isolation using cgroup cpusets to ensure accurate power measurements by shielding cores from system task interference.

**Main Scripts:**
- **`percluster_power.sh`** - Per-cluster power measurement (interactive prompts)
- **`single_power.sh`** - Single per-core power measurement (interactive prompts)
- **`rail_to_cluster.sh`** - CPU voltage rail logger for cluster identification
- **`x86_power.sh`** - Power measurement for x86/x64 workstations

## Tested Devices

- **Google Pixel 8 Pro** (9 cores: LITTLE 0-3, BIG 4-7, PRIME 8)
- **Samsung Galaxy A16** (8 cores: LITTLE 0-5, BIG 6-7)
- **x86 Intel Xeon W-2123 workstation**

## Prerequisites

### On Android Devices

- **Root access** (su)
- **Android Debug Bridge (adb)** connection
- Required binaries:
  - `stress-ng` (for CPU stress testing) - recommended
  - `taskset` (for CPU affinity control)
  - Access to `/sys` filesystem for power/thermal readings

### On x86 Workstations

- **Root/sudo access**
- Linux kernel with appropriate power monitoring interfaces
- `stress-ng` for CPU load generation

### On the Host Machine (for analysis)

- Python 3.x
- ADB installed and in PATH (for Android devices)
- USB debugging enabled on device

## Usage

### Option 1: Per-Cluster Measurement

Test an entire CPU cluster (e.g., all LITTLE cores or all BIG cores):

```bash
# 1. Push script to device
adb push percluster_power.sh /data/local/tmp/

# 2. Run interactively
adb shell
su
sh /data/local/tmp/percluster_power.sh
```

**Interactive Prompts:**
- Cluster name (e.g., "little", "big", "prime")
- All core numbers on device (e.g., "0 1 2 3 4 5 6 7 8")
- Cores in this cluster (e.g., "0 1 2 3" for LITTLE)
- Housekeeping core (usually "0")
- Duration per phase in seconds (default: 60)
- Sampling interval (default: 0.5)
- Idle gap between phases (default: 0)
- Output file suffix (default: "")

**Example Output:**
```
/data/local/tmp/little_core_power_cluster.csv
```

### Option 2: Single Per-Core Measurement

Test cores one at a time with a baseline housekeeping core:

```bash
# 1. Push script to device
adb push single_power.sh /data/local/tmp/

# 2. Run interactively
adb shell
su
sh /data/local/tmp/single_power.sh
```

**Interactive Prompts:**
- All core numbers on device
- Cores to test incrementally (e.g., "4 5 6 7" for BIG cluster)
- Housekeeping/system core (usually "0")
- Duration, interval, idle gap, suffix

**Example Phases** (testing cores 6,7 with system core 0):
- Phase 0: Cores 0+6 idle
- Phase 1: Cores 0+6 stressed
- Phase 2: Cores 0+7 idle  
- Phase 3: Cores 0+7 stressed

### Option 3: Voltage Rail Mapping

Identify which voltage regulators power which CPU clusters:

```bash
# 1. Push script to device
adb push rail_to_cluster.sh /data/local/tmp/

# 2. Run with manual frequency changes
adb shell
su
sh /data/local/tmp/rail_to_cluster.sh
```

**Interactive Prompts:**
- CPU policy numbers (e.g., "0 6" for policy0 and policy6)
- Regulator name patterns (e.g., "vproc11 vproc12")
- Phase durations

**Workflow:**
1. Script logs initial frequencies and voltages
2. Manually change CPU frequency using EX Kernel Manager or similar
3. Script detects changes and logs new values
4. Repeat for different clusters to map rails

### Option 4: x86 Workstation Measurement

For Intel/AMD desktop/server CPUs:

```bash
# Run locally on x86 machine (requires root)
sudo bash x86_power.sh
```

**Interactive Prompts:**
- Cores to test
- Measurement parameters

### Retrieve Results

```bash
# Pull CSV results from device
adb pull /data/local/tmp/*.csv ./csv_files/

# Or specific file
adb pull /data/local/tmp/little_core_power_cluster.csv ./csv_files/mobile_phone/
```


## License

This repository is for research and educational purposes.

**Related Publication:**  
*A Methodology to Assess Power Modeling in Energy-Aware Federated Learning on Heterogeneous Mobile Devices*

