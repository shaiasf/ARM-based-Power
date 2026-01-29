#!/system/bin/sh
# big_cluster_power.sh – Three-phase power test for BIG cluster with CPU shielding:
# Phase 0: Only CPU0 online, idle (baseline)
# Phase 1: BIG cores online, idle (no stress), CPU0 housekeeping
# Phase 2: BIG cores online, stressed, CPU0 housekeeping
# Uses cgroup cpusets to isolate cores from system tasks
# Root required.
# Usage:
#   adb push big_cluster_power.sh /data/local/tmp/
#   adb shell
#   su
#   sh /data/local/tmp/big_cluster_power.sh [duration_sec=600] [interval_s=0.5] [idle_gap_sec=300]

set -e

DURATION_SEC="${1:-60}"
INTERVAL="${2:-0.5}"
IDLE_GAP="${3:-0}"
MINMAX="${4:-}"
OUT_DIR="/data/local/tmp"
if [ -n "$MINMAX" ]; then
  LOG_PREFIX="$OUT_DIR/big_core_power_cluster_${MINMAX}"
else
  LOG_PREFIX="$OUT_DIR/big_core_power_cluster"
fi

mkdir -p "$OUT_DIR"

# --- Config ---
ALL_CORES="0 1 2 3 4 5 6 7"   # Adjust if your device has different topology
BIG_CORES="6 7"               # Define BIG cluster cores
SYSTEM_CORE="0"               # Core reserved for system tasks (housekeeping)

# --- Cgroup cpuset paths ---
CGROUP_ROOT="/dev/cpuset"
CGROUP_SYSTEM="$CGROUP_ROOT/system"
CGROUP_SHIELD="$CGROUP_ROOT/shield"

# ---- Sanity checks ---------------------------------------------------------
command -v stress-ng >/dev/null 2>&1 || { echo "[!] 'stress-ng' not found"; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "[!] 'taskset' not found"; exit 1; }
id | grep -q "uid=0" || { echo "[!] Run as root (su)"; exit 1; }

# ---- Cgroup cpuset helpers for CPU shielding -------------------------------

setup_cpusets() {
  echo "[*] Setting up cpuset cgroups for CPU shielding..."

  # Mount cpuset if not already mounted
  if [ ! -d "$CGROUP_ROOT" ]; then
    mkdir -p "$CGROUP_ROOT"
    mount -t cpuset none "$CGROUP_ROOT" 2>/dev/null || true
  fi

  # Create system and shield cpusets
  mkdir -p "$CGROUP_SYSTEM" 2>/dev/null || true
  mkdir -p "$CGROUP_SHIELD" 2>/dev/null || true

  # Initially assign all CPUs and all memory nodes to both
  echo "0-7" > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true
  echo "0" > "$CGROUP_SYSTEM/mems" 2>/dev/null || true
  echo "0-7" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
  echo "0" > "$CGROUP_SHIELD/mems" 2>/dev/null || true

  # Enable cpu_exclusive for shield
  echo 1 > "$CGROUP_SHIELD/cpu_exclusive" 2>/dev/null || true
}

move_tasks_to_system() {
  echo "[*] Moving all tasks to system cpuset (CPU $SYSTEM_CORE)..."

  # Set system cpuset to only use SYSTEM_CORE
  echo "$SYSTEM_CORE" > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true

  # Move all tasks from root cpuset to system cpuset
  for pid in $(cat "$CGROUP_ROOT/tasks" 2>/dev/null); do
    echo "$pid" > "$CGROUP_SYSTEM/tasks" 2>/dev/null || true
  done
}

update_shield_cores() {
  cores="$1"
  echo "[*] Updating shield cpuset to cores: $cores"

  # Convert space-separated list to comma format (e.g., "6 7" -> "6,7")
  core_list="$(echo "$cores" | tr ' ' ',')"
  echo "$core_list" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
}

move_pid_to_shield() {
  pid="$1"
  echo "$pid" > "$CGROUP_SHIELD/tasks" 2>/dev/null || true
}

cleanup_cpusets() {
  echo "[*] Cleaning up cpusets..."

  # Move all tasks back to root cpuset
  if [ -d "$CGROUP_SHIELD" ]; then
    for pid in $(cat "$CGROUP_SHIELD/tasks" 2>/dev/null); do
      echo "$pid" > "$CGROUP_ROOT/tasks" 2>/dev/null || true
    done
  fi

  if [ -d "$CGROUP_SYSTEM" ]; then
    for pid in $(cat "$CGROUP_SYSTEM/tasks" 2>/dev/null); do
      echo "$pid" > "$CGROUP_ROOT/tasks" 2>/dev/null || true
    done
  fi

  # Remove cpuset directories
  rmdir "$CGROUP_SHIELD" 2>/dev/null || true
  rmdir "$CGROUP_SYSTEM" 2>/dev/null || true
}

# ---- Keep screen on ---------------------------------------------------------
keep_screen_on() {
  echo "[*] Acquiring wakelock to keep screen on..."
  pm stay-awake true 2>/dev/null || true
}

release_screen_lock() {
  echo "[*] Releasing wakelock..."
  pm stay-awake false 2>/dev/null || true
}

# ---- Helpers ---------------------------------------------------------------
now_ms() {
  TS="$(date +%s%3N 2>/dev/null || true)"
  [ -n "$TS" ] || TS=$(( $(date +%s) * 1000 ))
  echo "$TS"
}

set_cpu_online() {
  local c="$1" val="$2"
  ONLINE_FILE="/sys/devices/system/cpu/cpu${c}/online"
  if [ "$c" = "0" ]; then
    # CPU0 is typically not hotpluggable
    return
  fi
  if [ -w "$ONLINE_FILE" ]; then
    echo "$val" > "$ONLINE_FILE" 2>/dev/null || true
  fi
}

read_voltage() {
  # Samsung A16 voltage path - adjust if needed
  local raw=""
  if [ -r /sys/class/power_supply/battery/voltage_now ]; then
    raw="$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)"
  fi
  [ -n "$raw" ] || raw=0
  local abs_raw="${raw#-}"
  local V
  if [ "$abs_raw" -ge 1000000 ]; then
    V="$(awk "BEGIN {printf(\"%.3f\", $raw/1000000.0)}")"
  else
    V="$(awk "BEGIN {printf(\"%.3f\", $raw/1000000.0)}")"
  fi
  echo "$V"
}

read_current() {
  # Samsung A16 current path - adjust if needed
  local raw=""
  if [ -r /sys/class/power_supply/battery/current_now ]; then
    raw="$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)"
  fi
  [ -n "$raw" ] || raw=0
  local abs_raw="${raw#-}"
  local mA
  if [ "$abs_raw" -ge 1000 ]; then
    mA="$(awk "BEGIN {printf(\"%.1f\", $abs_raw/1000.0)}")"
  else
    mA="$abs_raw"
  fi
  echo "$mA"
}

read_batt_temp() {
  # Battery temperature in °C
  local raw=""
  if [ -r /sys/class/power_supply/battery/temp ]; then
    raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)"
  else
    raw="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *temperature/ {print $2; exit}')"
  fi
  [ -n "$raw" ] || raw=0
  local abs_raw="${raw#-}"
  local C
  if [ "$abs_raw" -ge 1000 ]; then
    C="$(awk "BEGIN {printf(\"%.1f\", $raw/10.0)}")"
  else
    C="$raw"
  fi
  echo "$C"
}

read_cpu_temp() {
  # CPU temperature in °C (thermal_zone2)
  local raw=0
  if [ -r /sys/class/thermal/thermal_zone2/temp ]; then
    raw="$(cat /sys/class/thermal/thermal_zone2/temp 2>/dev/null || echo 0)"
  fi
  [ -n "$raw" ] || raw=0
  local C
  if [ "$raw" -ge 1000 ]; then
    C="$(awk "BEGIN {printf(\"%.1f\", $raw/1000.0)}")"
  else
    C="$raw"
  fi
  echo "$C"
}

read_freq() {
  local c="$1"
  FREQ_FILE="/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq"
  if [ -r "$FREQ_FILE" ]; then
    cat "$FREQ_FILE" 2>/dev/null || echo "offline"
  else
    echo "offline"
  fi
}

read_cpu_usage() {
  local c="$1"
  local STAT_FILE="/sys/devices/system/cpu/cpu${c}/cpufreq/stats/time_in_state"
  if [ ! -r "$STAT_FILE" ]; then
    echo "0.0"
    return
  fi

  local total=0
  local active=0
  while IFS= read -r line; do
    local freq=$(echo "$line" | awk '{print $1}')
    local time=$(echo "$line" | awk '{print $2}')
    total=$((total + time))
    if [ "$freq" != "0" ]; then
      active=$((active + time))
    fi
  done < "$STAT_FILE"

  if [ "$total" -gt 0 ]; then
    awk "BEGIN {printf(\"%.1f\", ($active * 100.0) / $total)}"
  else
    echo "0.0"
  fi
}

start_yes_mask() {
  local mask="$1"
  taskset "$mask" stress-ng --cpu 1 --cpu-method all --timeout 0 >/dev/null 2>&1 &
  echo $!
}

stop_yes() {
  killall stress-ng 2>/dev/null || true
  sleep 0.5
}

cleanup() {
  echo ""
  echo "[*] Cleaning up: killing stress-ng, restoring all cores online"
  stop_yes
  cleanup_cpusets
  release_screen_lock
  for c in $ALL_CORES; do set_cpu_online "$c" 1; done
  echo "[*] Online mask now: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
}
trap cleanup INT TERM

sample_power_csv() {
  local LABEL="$1"
  local CORE_LIST="$2"
  local LOG="$3"

  local COUNT=0
  local MAX_COUNT=$(awk "BEGIN {print int($DURATION_SEC / $INTERVAL)}")

  local sum_v=0 sum_i=0 sum_p=0 sum_bt=0 sum_ct=0
  local n=0

  echo "[*] Sampling for ${DURATION_SEC}s at ${INTERVAL}s intervals (phase=$LABEL)..."

  while [ "$COUNT" -lt "$MAX_COUNT" ]; do
    local TS="$(now_ms)"
    local V="$(read_voltage)"
    local I="$(read_current)"
    local P="$(awk "BEGIN {printf(\"%.4f\", $V * $I / 1000.0)}")"
    local BT="$(read_batt_temp)"
    local CT="$(read_cpu_temp)"

    {
      printf "%s,%s,%s,%s,%s,%s,%s,%s" "$TS" "$LABEL" "$CORE_LIST" "$V" "$I" "$P" "$BT" "$CT"
      for c in $ALL_CORES; do
        FRQ="$(read_freq "$c")"
        printf ",%s" "$FRQ"
      done
      for c in $ALL_CORES; do
        USG="$(read_cpu_usage "$c")"
        printf ",%s" "$USG"
      done
      printf "\n"
    } >> "$LOG"

    sum_v="$(awk "BEGIN {print $sum_v + $V}")"
    sum_i="$(awk "BEGIN {print $sum_i + $I}")"
    sum_p="$(awk "BEGIN {print $sum_p + $P}")"
    sum_bt="$(awk "BEGIN {print $sum_bt + $BT}")"
    sum_ct="$(awk "BEGIN {print $sum_ct + $CT}")"
    n=$((n + 1))

    COUNT=$((COUNT + 1))
    sleep "$INTERVAL"
  done

  local AVG_V="$(awk "BEGIN {printf(\"%.3f\", $sum_v / $n)}")"
  local AVG_I="$(awk "BEGIN {printf(\"%.1f\", $sum_i / $n)}")"
  local AVG_P="$(awk "BEGIN {printf(\"%.4f\", $sum_p / $n)}")"
  local AVG_BATT_TEMP="$(awk "BEGIN {printf(\"%.1f\", $sum_bt / $n)}")"
  local AVG_CPU_TEMP="$(awk "BEGIN {printf(\"%.1f\", $sum_ct / $n)}")"

  # Compute average frequency per core
  local AVG_FREQ_REPORT=""
  for c in $ALL_CORES; do
    if echo "$CORE_LIST" | grep -qw "$c" >/dev/null 2>&1; then
      local avg_freq_c="$(awk -F, -v ph="$LABEL" -v C=$((8 + c + 1)) \
        '$2==ph { if($C ~ /^[0-9]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
      AVG_FREQ_REPORT="${AVG_FREQ_REPORT}cpu${c}_freq=${avg_freq_c} "
    fi
  done

  # Append summary row to CSV
  {
    printf "# SUMMARY,%s,%s,%s,%s,%s,%s,%s" "$LABEL" "$CORE_LIST" "$AVG_V" "$AVG_I" "$AVG_P" "$AVG_BATT_TEMP" "$AVG_CPU_TEMP"
    # append per-core avg frequencies
    local num_cores=0
    for _ in $ALL_CORES; do num_cores=$((num_cores+1)); done
    for k in $ALL_CORES; do
      if echo "$CORE_LIST" | grep -qw "$k" >/dev/null 2>&1; then
        local col_freq_idx=0; local idx=0
        for kk in $ALL_CORES; do idx=$((idx+1)); if [ "$kk" = "$k" ]; then col_freq_idx=$((8 + idx)); break; fi; done
        if [ "$col_freq_idx" -ne 0 ]; then
          local avg_f="$(awk -F, -v ph="$LABEL" -v C="$col_freq_idx" '$2==ph { if($C ~ /^[0-9]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
          printf ",%s" "$avg_f"
        else
          printf ","
        fi
      else
        printf ","
      fi
    done
    # append per-core avg CPU usage
    num_cores=0
    for _ in $ALL_CORES; do num_cores=$((num_cores+1)); done
    for k in $ALL_CORES; do
      if echo "$CORE_LIST" | grep -qw "$k" >/dev/null 2>&1; then
        col_usage_idx=0; idx=0
        for kk in $ALL_CORES; do idx=$((idx+1)); if [ "$kk" = "$k" ]; then col_usage_idx=$((8 + num_cores + idx)); break; fi; done
        if [ "$col_usage_idx" -ne 0 ]; then
          avg_usage="$(awk -F, -v ph="$LABEL" -v C="$col_usage_idx" '$2==ph { if($C ~ /^[0-9.]+$/) {s+=$C; n++} } END { if(n>0) printf("%.1f", s/n); else print "offline" }' "$LOG")"
          printf ",%s" "$avg_usage"
        else
          printf ","
        fi
      else
        printf ","
      fi
    done
    printf "\n"
  } >> "$LOG"

  echo "[SUMMARY] Phase=$LABEL | corner=${MINMAX:-NA} | Avg Power=${AVG_P} W | Avg BattTemp=${AVG_BATT_TEMP}°C | Avg CPUTemp=${AVG_CPU_TEMP}°C"
  echo "$AVG_P $AVG_BATT_TEMP $AVG_CPU_TEMP $AVG_FREQ_REPORT"
}

idle_gap_wait() {
  if [ "$IDLE_GAP" -gt 0 ]; then
    echo "[*] Idle gap: waiting ${IDLE_GAP}s..."
    sleep "$IDLE_GAP"
  fi
}

# ---- Phases ----------------------------------------------------------------

run_baseline_phase() {
  echo "[+] Phase 0 (baseline): Only CPU0 online idle"

  # Turn off all cores except CPU0
  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      set_cpu_online "$c" 0
    fi
  done

  # Ensure CPU0 is online (it should always be)
  set_cpu_online "0" 1

  # No stress applied - CPU0 idle

  LOG="${LOG_PREFIX}.csv"
  CPU_SET="0"
  RES="$(sample_power_csv phase0_baseline "$CPU_SET" "$LOG")"
  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase 0 (baseline): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

run_idle_phase() {
  echo "[+] Phase 1 (idle): BIG cores (6-7) online idle, CPU0 housekeeping online idle"

  # Setup cpusets for shielding
  setup_cpusets
  move_tasks_to_system

  # Bring all BIG cores online
  for c in $BIG_CORES; do
    set_cpu_online "$c" 1
  done

  # Bring housekeeping core online
  set_cpu_online "$SYSTEM_CORE" 1

  # Turn off all other cores (not in BIG_CORES or SYSTEM_CORE)
  for c in $ALL_CORES; do
    if ! echo "$BIG_CORES $SYSTEM_CORE" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done

  # Update shield to include BIG cores
  update_shield_cores "$BIG_CORES"

  LOG="${LOG_PREFIX}.csv"
  CPU_SET="$(echo "$BIG_CORES" | tr ' ' '+')"
  RES="$(sample_power_csv phase1_idle "$CPU_SET" "$LOG")"
  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase 1 (idle): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

run_stress_phase() {
  echo "[+] Phase 2 (stress): BIG cores (6-7) online and stressed, CPU0 housekeeping online idle"

  # Ensure all BIG cores are online
  for c in $BIG_CORES; do
    set_cpu_online "$c" 1
  done

  # Ensure housekeeping core is online (but will NOT be stressed)
  set_cpu_online "$SYSTEM_CORE" 1

  # Ensure all other cores remain off
  for c in $ALL_CORES; do
    if ! echo "$BIG_CORES $SYSTEM_CORE" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done

  # Start stress ONLY on BIG cores (6-7), NOT on housekeeping core (0)
  PIDS=""
  for c in $BIG_CORES; do
    case "$c" in
      6) mask="40" ;;
      7) mask="80" ;;
      *) mask=$((1 << c)) ;;
    esac
    PID="$(start_yes_mask "$mask")"
    move_pid_to_shield "$PID"
    PIDS="$PIDS $PID"
    echo "[+] Started stress-ng: PID=$PID on CPU$c (mask=$mask), moved to shield"
  done

  LOG="${LOG_PREFIX}.csv"
  CPU_SET="$(echo "$BIG_CORES" | tr ' ' '+')"
  RES="$(sample_power_csv phase2_stress "$CPU_SET" "$LOG")"

  stop_yes

  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase 2 (stress): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

# ============================================================================
#                               MAIN
# ============================================================================

echo "=== BIG Cluster Power Test (Samsung A16) ==="
echo "BIG cores: $BIG_CORES"
echo "Duration per phase: ${DURATION_SEC}s; Sample interval: ${INTERVAL}s; Idle gap: ${IDLE_GAP}s"
echo "Initial online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
echo

keep_screen_on

LOG="${LOG_PREFIX}.csv"
# Write header once
{
  printf "timestamp_ms,phase,cpu_set,voltage_V,current_mA,power_W,batt_temp,cpu_temp"
  for c in $ALL_CORES; do printf ",freq_cpu%s" "$c"; done
  for c in $ALL_CORES; do printf ",cpu_usage_%s" "$c"; done
  printf "\n"
} > "$LOG"

run_baseline_phase
idle_gap_wait

run_idle_phase

run_stress_phase

echo
echo "=== Done ==="
echo "CSV file:"
echo "  ${LOG_PREFIX}.csv"

# Restore all cores online
for c in $ALL_CORES; do set_cpu_online "$c" 1; done
echo "Restored online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"

cleanup

