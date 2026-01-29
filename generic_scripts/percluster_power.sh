#!/system/bin/sh
# universal_cluster_power.sh – Universal per-cluster power measurement script
# Works with any device and cluster configuration via user input
# Root required.
#
# Usage:
#   adb push universal_cluster_power.sh /data/local/tmp/
#   adb shell
#   su
#   sh /data/local/tmp/universal_cluster_power.sh
#
# The script will prompt you for:
#   - Cluster name (e.g., "little", "big", "prime")
#   - Core numbers in the cluster
#   - Measurement parameters

set -e

# ============================================================================
#                           INTERACTIVE CONFIGURATION
# ============================================================================

echo "======================================================================"
echo "           Universal CPU Cluster Power Measurement Script"
echo "======================================================================"
echo ""

# Get cluster name
echo "Enter cluster name (e.g., little, big, prime):"
read CLUSTER_NAME
CLUSTER_NAME="${CLUSTER_NAME:-cluster}"

# Get core configuration
echo ""
echo "Enter ALL core numbers on device (space-separated, e.g., 0 1 2 3 4 5 6 7 8):"
read ALL_CORES
ALL_CORES="${ALL_CORES:-0 1 2 3 4 5 6 7}"

echo ""
echo "Enter cores in THIS cluster (space-separated, e.g., 0 1 2 3):"
read CLUSTER_CORES
CLUSTER_CORES="${CLUSTER_CORES:-0 1 2 3}"

# Get housekeeping core
echo ""
echo "Enter housekeeping core (usually 0):"
read SYSTEM_CORE
SYSTEM_CORE="${SYSTEM_CORE:-0}"

# Get measurement parameters
echo ""
echo "Enter duration per phase in seconds (default: 60):"
read DURATION_SEC
DURATION_SEC="${DURATION_SEC:-60}"

echo ""
echo "Enter sampling interval in seconds (default: 0.5):"
read INTERVAL
INTERVAL="${INTERVAL:-0.5}"

echo ""
echo "Enter idle gap between phases in seconds (default: 0):"
read IDLE_GAP
IDLE_GAP="${IDLE_GAP:-0}"

echo ""
echo "Enter corner label (min/max/typical, or leave empty):"
read MINMAX

# Output directory and file naming
OUT_DIR="/data/local/tmp"
if [ -n "$MINMAX" ]; then
  LOG_PREFIX="$OUT_DIR/${CLUSTER_NAME}_core_power_cluster_${MINMAX}"
else
  LOG_PREFIX="$OUT_DIR/${CLUSTER_NAME}_core_power_cluster"
fi

# Display configuration
echo ""
echo "======================================================================"
echo "                      CONFIGURATION SUMMARY"
echo "======================================================================"
echo "Cluster:              $CLUSTER_NAME"
echo "All cores:            $ALL_CORES"
echo "Cluster cores:        $CLUSTER_CORES"
echo "Housekeeping core:    $SYSTEM_CORE"
echo "Duration per phase:   ${DURATION_SEC}s"
echo "Sampling interval:    ${INTERVAL}s"
echo "Idle gap:             ${IDLE_GAP}s"
echo "Corner:               ${MINMAX:-N/A}"
echo "Output file:          ${LOG_PREFIX}.csv"
echo "======================================================================"
echo ""
echo "Press ENTER to continue or Ctrl+C to cancel..."
read CONFIRM

mkdir -p "$OUT_DIR"

# Cgroup cpuset paths
CGROUP_ROOT="/dev/cpuset"
CGROUP_SYSTEM="$CGROUP_ROOT/system"
CGROUP_SHIELD="$CGROUP_ROOT/shield"

# ============================================================================
#                              SANITY CHECKS
# ============================================================================

command -v stress-ng >/dev/null 2>&1 || command -v yes >/dev/null 2>&1 || { echo "[!] Neither 'stress-ng' nor 'yes' found"; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "[!] 'taskset' not found"; exit 1; }
id | grep -q "uid=0" || { echo "[!] Run as root (su)"; exit 1; }

# Determine stress tool
if command -v stress-ng >/dev/null 2>&1; then
  STRESS_TOOL="stress-ng"
  echo "[*] Using stress-ng for CPU stress"
else
  STRESS_TOOL="yes"
  echo "[*] Using yes for CPU stress"
fi

# ============================================================================
#                      CGROUP CPUSET HELPERS (CPU SHIELDING)
# ============================================================================

setup_cpusets() {
  echo "[*] Setting up cpuset cgroups for CPU shielding..."

  if [ ! -d "$CGROUP_ROOT" ]; then
    mkdir -p "$CGROUP_ROOT"
    mount -t cpuset none "$CGROUP_ROOT" 2>/dev/null || true
  fi

  mkdir -p "$CGROUP_SYSTEM" 2>/dev/null || true
  mkdir -p "$CGROUP_SHIELD" 2>/dev/null || true

  # Get max core number for range
  MAX_CORE=0
  for c in $ALL_CORES; do
    [ "$c" -gt "$MAX_CORE" ] && MAX_CORE="$c"
  done

  echo "0-${MAX_CORE}" > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true
  echo "0" > "$CGROUP_SYSTEM/mems" 2>/dev/null || true
  echo "0-${MAX_CORE}" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
  echo "0" > "$CGROUP_SHIELD/mems" 2>/dev/null || true

  echo 1 > "$CGROUP_SHIELD/cpu_exclusive" 2>/dev/null || true
}

move_tasks_to_system() {
  echo "[*] Moving all tasks to system cpuset (CPU $SYSTEM_CORE)..."

  echo "$SYSTEM_CORE" > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true

  for pid in $(cat "$CGROUP_ROOT/tasks" 2>/dev/null); do
    echo "$pid" > "$CGROUP_SYSTEM/tasks" 2>/dev/null || true
  done
}

update_shield_cores() {
  cores="$1"
  echo "[*] Updating shield cpuset to cores: $cores"

  core_list="$(echo "$cores" | tr ' ' ',')"
  echo "$core_list" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
}

move_pid_to_shield() {
  pid="$1"
  echo "$pid" > "$CGROUP_SHIELD/tasks" 2>/dev/null || true
}

cleanup_cpusets() {
  echo "[*] Cleaning up cpusets..."

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

  rmdir "$CGROUP_SHIELD" 2>/dev/null || true
  rmdir "$CGROUP_SYSTEM" 2>/dev/null || true
}

# ============================================================================
#                         SCREEN WAKELOCK MANAGEMENT
# ============================================================================

keep_screen_on() {
  echo "[*] Acquiring wakelock to keep screen on..."
  pm stay-awake true 2>/dev/null || true
}

release_screen_lock() {
  echo "[*] Releasing wakelock..."
  pm stay-awake false 2>/dev/null || true
}

# ============================================================================
#                              HELPER FUNCTIONS
# ============================================================================

now_ms() {
  TS="$(date +%s%3N 2>/dev/null || true)"
  [ -n "$TS" ] || TS=$(( $(date +%s) * 1000 ))
  echo "$TS"
}

set_cpu_online() {
  c="$1"
  val="$2"
  ONLINE_FILE="/sys/devices/system/cpu/cpu${c}/online"
  if [ "$c" = "0" ]; then
    return
  fi
  if [ -w "$ONLINE_FILE" ]; then
    echo "$val" > "$ONLINE_FILE" 2>/dev/null || true
  fi
}

read_voltage() {
  raw=""
  if [ -r /sys/class/power_supply/battery/voltage_now ]; then
    raw="$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null || echo 0)"
  fi
  [ -n "$raw" ] || raw=0
  abs_raw="${raw#-}"
  if [ "$abs_raw" -ge 1000000 ]; then
    V="$(awk "BEGIN {printf(\"%.3f\", $raw/1000000.0)}")"
  else
    V="$(awk "BEGIN {printf(\"%.3f\", $raw/1000000.0)}")"
  fi
  echo "$V"
}

read_current() {
  raw=""
  if [ -r /sys/class/power_supply/battery/current_now ]; then
    raw="$(cat /sys/class/power_supply/battery/current_now 2>/dev/null || echo 0)"
  fi
  [ -n "$raw" ] || raw=0
  abs_raw="${raw#-}"
  if [ "$abs_raw" -ge 1000 ]; then
    mA="$(awk "BEGIN {printf(\"%.1f\", $abs_raw/1000.0)}")"
  else
    mA="$abs_raw"
  fi
  echo "$mA"
}

read_batt_temp() {
  raw=""
  if [ -r /sys/class/power_supply/battery/temp ]; then
    raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)"
  else
    raw="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *temperature/ {print $2; exit}')"
  fi
  [ -n "$raw" ] || raw=0
  abs_raw="${raw#-}"
  if [ "$abs_raw" -ge 1000 ]; then
    C="$(awk "BEGIN {printf(\"%.1f\", $raw/10.0)}")"
  else
    C="$raw"
  fi
  echo "$C"
}

read_cpu_temp() {
  raw=0
  # Try common thermal zones
  for zone in 0 1 2 3 4 5; do
    if [ -r /sys/class/thermal/thermal_zone${zone}/temp ]; then
      raw="$(cat /sys/class/thermal/thermal_zone${zone}/temp 2>/dev/null || echo 0)"
      break
    fi
  done
  [ -n "$raw" ] || raw=0
  if [ "$raw" -ge 1000 ]; then
    C="$(awk "BEGIN {printf(\"%.1f\", $raw/1000.0)}")"
  else
    C="$raw"
  fi
  echo "$C"
}

read_freq() {
  c="$1"
  FREQ_FILE="/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq"
  if [ -r "$FREQ_FILE" ]; then
    cat "$FREQ_FILE" 2>/dev/null || echo "offline"
  else
    echo "offline"
  fi
}

read_cpu_usage() {
  c="$1"
  STAT_FILE="/sys/devices/system/cpu/cpu${c}/cpufreq/stats/time_in_state"
  if [ ! -r "$STAT_FILE" ]; then
    echo "0.0"
    return
  fi

  total=0
  active=0
  while IFS= read -r line; do
    freq=$(echo "$line" | awk '{print $1}')
    time=$(echo "$line" | awk '{print $2}')
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

# Get CPU affinity mask for a given core number
get_cpu_mask() {
  c="$1"
  case "$c" in
    0) echo "1" ;;
    1) echo "2" ;;
    2) echo "4" ;;
    3) echo "8" ;;
    4) echo "10" ;;
    5) echo "20" ;;
    6) echo "40" ;;
    7) echo "80" ;;
    8) echo "100" ;;
    9) echo "200" ;;
    10) echo "400" ;;
    11) echo "800" ;;
    *) echo "$((1 << c))" ;;
  esac
}

start_stress_process() {
  mask="$1"
  if [ "$STRESS_TOOL" = "stress-ng" ]; then
    taskset "$mask" stress-ng --cpu 1 --cpu-method all -t 0 >/dev/null 2>&1 &
  else
    taskset "$mask" yes >/dev/null 2>&1 &
  fi
  echo $!
}

stop_stress() {
  if [ "$STRESS_TOOL" = "stress-ng" ]; then
    killall stress-ng 2>/dev/null || true
  else
    killall yes 2>/dev/null || true
  fi
  sleep 0.5
}

cleanup() {
  echo ""
  echo "[*] Cleaning up: killing stress, restoring all cores online"
  stop_stress
  cleanup_cpusets
  release_screen_lock
  for c in $ALL_CORES; do set_cpu_online "$c" 1; done
  echo "[*] Online mask now: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
}
trap cleanup INT TERM

# ============================================================================
#                         POWER SAMPLING FUNCTION
# ============================================================================

sample_power_csv() {
  LABEL="$1"
  CORE_LIST="$2"
  LOG="$3"

  COUNT=0
  MAX_COUNT=$(awk "BEGIN {print int($DURATION_SEC / $INTERVAL)}")

  sum_v=0
  sum_i=0
  sum_p=0
  sum_bt=0
  sum_ct=0
  n=0

  echo "[*] Sampling for ${DURATION_SEC}s at ${INTERVAL}s intervals (phase=$LABEL)..."

  while [ "$COUNT" -lt "$MAX_COUNT" ]; do
    TS="$(now_ms)"
    V="$(read_voltage)"
    I="$(read_current)"
    P="$(awk "BEGIN {printf(\"%.4f\", $V * $I / 1000.0)}")"
    BT="$(read_batt_temp)"
    CT="$(read_cpu_temp)"

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

  AVG_V="$(awk "BEGIN {printf(\"%.3f\", $sum_v / $n)}")"
  AVG_I="$(awk "BEGIN {printf(\"%.1f\", $sum_i / $n)}")"
  AVG_P="$(awk "BEGIN {printf(\"%.4f\", $sum_p / $n)}")"
  AVG_BATT_TEMP="$(awk "BEGIN {printf(\"%.1f\", $sum_bt / $n)}")"
  AVG_CPU_TEMP="$(awk "BEGIN {printf(\"%.1f\", $sum_ct / $n)}")"

  # Compute average frequency per core
  AVG_FREQ_REPORT=""
  for c in $ALL_CORES; do
    if echo "$CORE_LIST" | grep -qw "$c" >/dev/null 2>&1; then
      avg_freq_c="$(awk -F, -v ph="$LABEL" -v C=$((8 + c + 1)) \
        '$2==ph { if($C ~ /^[0-9]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
      AVG_FREQ_REPORT="${AVG_FREQ_REPORT}cpu${c}_freq=${avg_freq_c} "
    fi
  done

  # Append summary row to CSV
  {
    printf "SUMMARY,%s,%s,%s,%s,%s,%s,%s" "$LABEL" "$CORE_LIST" "$AVG_V" "$AVG_I" "$AVG_P" "$AVG_BATT_TEMP" "$AVG_CPU_TEMP"
    num_cores=0
    for _ in $ALL_CORES; do num_cores=$((num_cores+1)); done
    for k in $ALL_CORES; do
      if echo "$CORE_LIST" | grep -qw "$k" >/dev/null 2>&1; then
        col_freq_idx=0
        idx=0
        for kk in $ALL_CORES; do
          idx=$((idx+1))
          if [ "$kk" = "$k" ]; then
            col_freq_idx=$((8 + idx))
            break
          fi
        done
        if [ "$col_freq_idx" -ne 0 ]; then
          avg_f="$(awk -F, -v ph="$LABEL" -v C="$col_freq_idx" '$2==ph { if($C ~ /^[0-9]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
          printf ",%s" "$avg_f"
        else
          printf ","
        fi
      else
        printf ","
      fi
    done
    num_cores=0
    for _ in $ALL_CORES; do num_cores=$((num_cores+1)); done
    for k in $ALL_CORES; do
      if echo "$CORE_LIST" | grep -qw "$k" >/dev/null 2>&1; then
        col_usage_idx=0
        idx=0
        for kk in $ALL_CORES; do
          idx=$((idx+1))
          if [ "$kk" = "$k" ]; then
            col_usage_idx=$((8 + num_cores + idx))
            break
          fi
        done
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

# ============================================================================
#                                 PHASES
# ============================================================================

run_baseline_phase() {
  echo "[+] Phase 0 (baseline): Only CPU0 online idle"

  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      set_cpu_online "$c" 0
    fi
  done

  set_cpu_online "0" 1

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
  echo "[+] Phase 1 (idle): Cluster cores online idle, CPU${SYSTEM_CORE} housekeeping online idle"

  setup_cpusets
  move_tasks_to_system

  for c in $CLUSTER_CORES; do
    set_cpu_online "$c" 1
  done

  set_cpu_online "$SYSTEM_CORE" 1

  for c in $ALL_CORES; do
    if ! echo "$CLUSTER_CORES $SYSTEM_CORE" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done

  update_shield_cores "$CLUSTER_CORES"

  LOG="${LOG_PREFIX}.csv"
  CPU_SET="$(echo "$CLUSTER_CORES" | tr ' ' '+')"
  RES="$(sample_power_csv phase1_idle "$CPU_SET" "$LOG")"
  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase 1 (idle): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

run_stress_phase() {
  echo "[+] Phase 2 (stress): Cluster cores online and stressed, CPU${SYSTEM_CORE} housekeeping online idle"

  for c in $CLUSTER_CORES; do
    set_cpu_online "$c" 1
  done

  set_cpu_online "$SYSTEM_CORE" 1

  for c in $ALL_CORES; do
    if ! echo "$CLUSTER_CORES $SYSTEM_CORE" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done

  PIDS=""
  for c in $CLUSTER_CORES; do
    mask="$(get_cpu_mask "$c")"
    PID="$(start_stress_process "$mask")"
    move_pid_to_shield "$PID"
    PIDS="$PIDS $PID"
    echo "[+] Started stress: PID=$PID on CPU$c (mask=$mask), moved to shield"
  done

  LOG="${LOG_PREFIX}.csv"
  CPU_SET="$(echo "$CLUSTER_CORES" | tr ' ' '+')"
  RES="$(sample_power_csv phase2_stress "$CPU_SET" "$LOG")"

  stop_stress

  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase 2 (stress): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

# ============================================================================
#                                  MAIN
# ============================================================================

echo ""
echo "=== ${CLUSTER_NAME} Cluster Power Test ==="
echo "Cluster cores: $CLUSTER_CORES"
echo "Duration per phase: ${DURATION_SEC}s; Sample interval: ${INTERVAL}s; Idle gap: ${IDLE_GAP}s"
echo "Initial online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
echo ""

keep_screen_on

LOG="${LOG_PREFIX}.csv"
# Write header
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

echo ""
echo "=== Done ==="
echo "CSV file:"
echo "  ${LOG_PREFIX}.csv"

for c in $ALL_CORES; do set_cpu_online "$c" 1; done
echo "Restored online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"

cleanup