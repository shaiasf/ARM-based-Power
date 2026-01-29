#!/system/bin/sh
# universal_incremental_power.sh – Universal incremental per-core power measurement
# Tests cores incrementally with system core as baseline
# Root required.
#
# Usage:
#   adb push universal_incremental_power.sh /data/local/tmp/
#   adb shell
#   su
#   sh /data/local/tmp/universal_incremental_power.sh
#
# The script will prompt you for:
#   - Core numbers to test
#   - System/housekeeping core
#   - Measurement parameters

set -e

# ============================================================================
#                           INTERACTIVE CONFIGURATION
# ============================================================================

echo "======================================================================"
echo "    Universal Incremental CPU Core Power Measurement Script"
echo "======================================================================"
echo ""
echo "This script tests cores incrementally, keeping a system core as baseline."
echo "Example: If testing cores 6,7 with system core 0:"
echo "  - Phase 0: 0+6 idle"
echo "  - Phase 1: 0+6 stressed"
echo "  - Phase 2: 0+7 idle"
echo "  - Phase 3: 0+7 stressed"
echo ""

# Get all cores
echo "Enter ALL core numbers on device (space-separated, e.g., 0 1 2 3 4 5 6 7):"
read ALL_CORES
ALL_CORES="${ALL_CORES:-0 1 2 3 4 5 6 7}"

# Get cores to test
echo ""
echo "Enter cores to TEST incrementally (space-separated, e.g., 6 7):"
echo "(Each will be tested with system core, one at a time)"
read CORES_TO_TEST
CORES_TO_TEST="${CORES_TO_TEST:-6 7}"

# Get housekeeping core
echo ""
echo "Enter housekeeping/system core (usually 0):"
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

# Generate descriptive name for output file
CORES_DESC="$(echo "$CORES_TO_TEST" | tr ' ' '_')"

# Output directory and file naming
OUT_DIR="/data/local/tmp"
if [ -n "$MINMAX" ]; then
  LOG_PREFIX="$OUT_DIR/incremental_cores_${CORES_DESC}_${MINMAX}"
else
  LOG_PREFIX="$OUT_DIR/incremental_cores_${CORES_DESC}"
fi

# Display configuration
echo ""
echo "======================================================================"
echo "                      CONFIGURATION SUMMARY"
echo "======================================================================"
echo "All cores:            $ALL_CORES"
echo "Cores to test:        $CORES_TO_TEST"
echo "System core:          $SYSTEM_CORE"
echo "Duration per phase:   ${DURATION_SEC}s"
echo "Sampling interval:    ${INTERVAL}s"
echo "Idle gap:             ${IDLE_GAP}s"
echo "Corner:               ${MINMAX:-N/A}"
echo "Output file:          ${LOG_PREFIX}.csv"
echo ""
echo "Test sequence:"
PHASE_NUM=0
for core in $CORES_TO_TEST; do
  echo "  Phase $PHASE_NUM: cores ${SYSTEM_CORE}+${core} idle"
  PHASE_NUM=$((PHASE_NUM + 1))
  echo "  Phase $PHASE_NUM: cores ${SYSTEM_CORE}+${core} stressed"
  PHASE_NUM=$((PHASE_NUM + 1))
done
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

setup_cgroups() {
  echo "[*] Setting up cgroup cpusets for CPU shielding..."

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

  echo "[*] Cgroup cpusets created"
}

move_tasks_to_system() {
  echo "[*] Moving all tasks to system core ($SYSTEM_CORE)..."

  echo "$SYSTEM_CORE" > "$CGROUP_SYSTEM/cpus" 2>/dev/null || true

  for pid in $(cat "$CGROUP_ROOT/tasks" 2>/dev/null); do
    echo "$pid" > "$CGROUP_SYSTEM/tasks" 2>/dev/null || true
  done

  if [ -r "$CGROUP_SHIELD/tasks" ]; then
    for pid in $(cat "$CGROUP_SHIELD/tasks" 2>/dev/null); do
      echo "$pid" > "$CGROUP_SYSTEM/tasks" 2>/dev/null || true
    done
  fi

  echo "[*] All tasks moved to system core"
}

update_shield_cores() {
  CORES_TO_SHIELD="$1"

  if [ -z "$CORES_TO_SHIELD" ]; then
    echo "" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
    return
  fi

  SHIELD_CPUS="$(echo "$CORES_TO_SHIELD" | tr ' ' ',')"
  echo "[*] Shielding cores: $SHIELD_CPUS"
  echo "$SHIELD_CPUS" > "$CGROUP_SHIELD/cpus" 2>/dev/null || true
}

cleanup_cgroups() {
  echo "[*] Cleaning up cgroups..."

  if [ -r "$CGROUP_SYSTEM/tasks" ]; then
    for pid in $(cat "$CGROUP_SYSTEM/tasks" 2>/dev/null); do
      echo "$pid" > "$CGROUP_ROOT/tasks" 2>/dev/null || true
    done
  fi

  if [ -r "$CGROUP_SHIELD/tasks" ]; then
    for pid in $(cat "$CGROUP_SHIELD/tasks" 2>/dev/null); do
      echo "$pid" > "$CGROUP_ROOT/tasks" 2>/dev/null || true
    done
  fi

  rmdir "$CGROUP_SYSTEM" 2>/dev/null || true
  rmdir "$CGROUP_SHIELD" 2>/dev/null || true

  echo "[*] Cgroups cleaned up"
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

cpu_is_online() {
  cpu="$1"
  f="/sys/devices/system/cpu/cpu$cpu/online"
  if [ ! -e "$f" ]; then
    [ "$cpu" = "0" ] && echo 1 && return
  fi
  if [ -r "$f" ]; then
    cat "$f"
  else
    echo 0
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
  if [ "$(cpu_is_online "$c")" != "1" ]; then
    echo "offline"
    return
  fi
  FREQ_FILE="/sys/devices/system/cpu/cpu${c}/cpufreq/scaling_cur_freq"
  if [ -r "$FREQ_FILE" ]; then
    cat "$FREQ_FILE" 2>/dev/null || echo "offline"
  else
    echo "offline"
  fi
}

read_cpu_usage() {
  cpu="$1"
  prev_stat="$2"
  curr_stat="$3"

  if [ "$(cpu_is_online "$cpu")" != "1" ]; then
    echo "offline"
    return
  fi

  prev_line="$(echo "$prev_stat" | sed -n "s/^cpu${cpu} //p")"
  curr_line="$(echo "$curr_stat" | sed -n "s/^cpu${cpu} //p")"

  if [ -z "$prev_line" ] || [ -z "$curr_line" ]; then
    echo "0"
    return
  fi

  prev_user=$(echo "$prev_line" | awk '{print $1}'); curr_user=$(echo "$curr_line" | awk '{print $1}')
  prev_nice=$(echo "$prev_line" | awk '{print $2}'); curr_nice=$(echo "$curr_line" | awk '{print $2}')
  prev_system=$(echo "$prev_line" | awk '{print $3}'); curr_system=$(echo "$curr_line" | awk '{print $3}')
  prev_idle=$(echo "$prev_line" | awk '{print $4}'); curr_idle=$(echo "$curr_line" | awk '{print $4}')
  prev_iowait=$(echo "$prev_line" | awk '{print $5}'); curr_iowait=$(echo "$curr_line" | awk '{print $5}')
  prev_irq=$(echo "$prev_line" | awk '{print $6}'); curr_irq=$(echo "$curr_line" | awk '{print $6}')
  prev_softirq=$(echo "$prev_line" | awk '{print $7}'); curr_softirq=$(echo "$curr_line" | awk '{print $7}')

  d_user=$((curr_user - prev_user))
  d_nice=$((curr_nice - prev_nice))
  d_system=$((curr_system - prev_system))
  d_idle=$((curr_idle - prev_idle))
  d_iowait=$((curr_iowait - prev_iowait))
  d_irq=$((curr_irq - prev_irq))
  d_softirq=$((curr_softirq - prev_softirq))

  d_total=$((d_user + d_nice + d_system + d_idle + d_iowait + d_irq + d_softirq))
  if [ "$d_total" -eq 0 ]; then
    echo "0"
  else
    d_work=$((d_total - d_idle))
    pct=$(awk -v w="$d_work" -v t="$d_total" 'BEGIN{printf("%.1f", (w/t)*100)}')
    echo "$pct"
  fi
}

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
  PID=$!
  echo "$PID" > "$CGROUP_SHIELD/tasks" 2>/dev/null || true
  echo $PID
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
  release_screen_lock
  cleanup_cgroups
  for c in $ALL_CORES; do set_cpu_online "$c" 1; done
  echo "[*] Online mask now: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
}
trap cleanup INT TERM

# ============================================================================
#                         POWER SAMPLING FUNCTION
# ============================================================================

sample_power_csv() {
  LABEL="$1"
  CPU_SET="$2"
  LOG="$3"

  printf "\n" >> "$LOG"

  PROC_STAT_PREV="$(cat /proc/stat 2>/dev/null)"

  START="$(now_ms)"
  while : ; do
    NOW="$(now_ms)"
    ELAPSED=$(( NOW - START ))
    [ "$ELAPSED" -ge $(( DURATION_SEC * 1000 )) ] && break

    V="$(read_voltage)"
    I="$(read_current)"
    P="$(awk "BEGIN {printf(\"%.6f\", $V * $I / 1000.0)}")"
    BT="$(read_batt_temp)"
    CT="$(read_cpu_temp)"

    PROC_STAT_CURR="$(cat /proc/stat 2>/dev/null)"

    {
      printf "%s,%s,%s,%s,%s,%s,%s,%s" "$(now_ms)" "$LABEL" "$CPU_SET" "$V" "$I" "$P" "$BT" "$CT"
      for c in $ALL_CORES; do
        FRQ="$(read_freq "$c")"
        printf ",%s" "$FRQ"
      done
      for c in $ALL_CORES; do
        USG="$(read_cpu_usage "$c" "$PROC_STAT_PREV" "$PROC_STAT_CURR")"
        printf ",%s" "$USG"
      done
      printf "\n"
    } >> "$LOG"

    PROC_STAT_PREV="$PROC_STAT_CURR"
    sleep "$INTERVAL" 2>/dev/null || sleep 1
  done

  AVG_PWR="$(awk -F, -v ph="$LABEL" '$2==ph && $6 ~ /^[0-9.]+$/ {sum+=$6; n++} END {if(n>0) printf("%.6f", sum/n); else print "0"}' "$LOG")"
  AVG_BATT_TEMP="$(awk -F, -v ph="$LABEL" '$2==ph && $7 ~ /^[0-9.]+$/ {sum+=$7; n++} END {if(n>0) printf("%.1f", sum/n); else print "0.0"}' "$LOG")"
  AVG_CPU_TEMP="$(awk -F, -v ph="$LABEL" '$2==ph && $8 ~ /^[0-9.]+$/ {sum+=$8; n++} END {if(n>0) printf("%.1f", sum/n); else print "0.0"}' "$LOG")"

  CORE_LIST="$(echo "$CPU_SET" | tr '+' ' ')"
  AVG_FREQ_REPORT=""

  for c in $CORE_LIST; do
    idx=0; col=0
    for k in $ALL_CORES; do
      idx=$((idx+1))
      if [ "$k" = "$c" ]; then col=$((8+idx)); break; fi
    done
    if [ "$col" -eq 0 ]; then
      AVG_FREQ_REPORT="${AVG_FREQ_REPORT} cpu${c}=NA"
      continue
    fi
    avgf="$(awk -F, -v ph="$LABEL" -v C="$col" '$2==ph { if($C ~ /^[0-9.]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
    AVG_FREQ_REPORT="${AVG_FREQ_REPORT} cpu${c}=${avgf}Hz"
  done

  SUMMARY_TS="$(now_ms)"
  {
    printf "%s,SUMMARY,%s,,,%.6f,%.1f,%.1f" "$SUMMARY_TS" "$LABEL" "$AVG_PWR" "$AVG_BATT_TEMP" "$AVG_CPU_TEMP"

    for k in $ALL_CORES; do
      if echo "$CORE_LIST" | grep -qw "$k" >/dev/null 2>&1; then
        col_idx=0; idx=0
        for kk in $ALL_CORES; do idx=$((idx+1)); if [ "$kk" = "$k" ]; then col_idx=$((8+idx)); break; fi; done
        if [ "$col_idx" -ne 0 ]; then
          avgf="$(awk -F, -v ph="$LABEL" -v C="$col_idx" '$2==ph { if($C ~ /^[0-9.]+$/) {s+=$C; n++} } END { if(n>0) printf("%.0f", s/n); else print "offline" }' "$LOG")"
          printf ",%s" "$avgf"
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

  echo "[SUMMARY] Phase=$LABEL | corner=${MINMAX:-NA} | Avg Power=${AVG_PWR} W | Avg BattTemp=${AVG_BATT_TEMP}°C | Avg CPUTemp=${AVG_CPU_TEMP}°C"
  echo "$AVG_PWR $AVG_BATT_TEMP $AVG_CPU_TEMP $AVG_FREQ_REPORT"
}

idle_gap_wait() {
  if [ "$IDLE_GAP" -gt 0 ]; then
    echo "[*] Idle gap: waiting ${IDLE_GAP}s..."
    sleep "$IDLE_GAP"
  fi
}

# ============================================================================
#                           PHASE FUNCTIONS
# ============================================================================

run_idle_phase() {
  PHASE_NUM="$1"
  CORE_CONFIG="$2"

  CPU_SET="$(echo "$CORE_CONFIG" | tr ' ' '+')"

  echo "[+] Phase ${PHASE_NUM} (idle): cores $CPU_SET online, no stress, SHIELDED from tasks"

  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      set_cpu_online "$c" 0
    fi
  done

  sleep 0.2

  for c in $CORE_CONFIG; do
    set_cpu_online "$c" 1
  done

  sleep 0.2

  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      should_be_on=0
      for target in $CORE_CONFIG; do
        if [ "$c" = "$target" ]; then
          should_be_on=1
          break
        fi
      done
      if [ "$should_be_on" = "0" ]; then
        set_cpu_online "$c" 0
      fi
    fi
  done

  echo "[DEBUG] Requested cores: $CPU_SET, Actual online: $(cat /sys/devices/system/cpu/online 2>/dev/null)"

  CORES_TO_SHIELD=""
  for c in $CORE_CONFIG; do
    if [ "$c" != "$SYSTEM_CORE" ]; then
      CORES_TO_SHIELD="$CORES_TO_SHIELD $c"
    fi
  done
  CORES_TO_SHIELD="$(echo "$CORES_TO_SHIELD" | sed 's/^ *//')"

  update_shield_cores "$CORES_TO_SHIELD"
  move_tasks_to_system

  LOG="${LOG_PREFIX}.csv"
  PHASE_LABEL="phase${PHASE_NUM}_idle_${CPU_SET}"
  RES="$(sample_power_csv "$PHASE_LABEL" "$CPU_SET" "$LOG")"
  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase ${PHASE_NUM} (idle $CPU_SET): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

run_stress_phase() {
  PHASE_NUM="$1"
  CORE_CONFIG="$2"

  CPU_SET="$(echo "$CORE_CONFIG" | tr ' ' '+')"

  echo "[+] Phase ${PHASE_NUM} (stress): cores $CPU_SET online and stressed, OTHER tasks on system core"

  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      set_cpu_online "$c" 0
    fi
  done

  sleep 0.2

  for c in $CORE_CONFIG; do
    set_cpu_online "$c" 1
  done

  sleep 0.2

  for c in $ALL_CORES; do
    if [ "$c" != "0" ]; then
      should_be_on=0
      for target in $CORE_CONFIG; do
        if [ "$c" = "$target" ]; then
          should_be_on=1
          break
        fi
      done
      if [ "$should_be_on" = "0" ]; then
        set_cpu_online "$c" 0
      fi
    fi
  done

  echo "[DEBUG] Requested cores: $CPU_SET, Actual online: $(cat /sys/devices/system/cpu/online 2>/dev/null)"

  update_shield_cores "$CORE_CONFIG"
  move_tasks_to_system

  PIDS=""
  for c in $CORE_CONFIG; do
    [ "$c" = "$SYSTEM_CORE" ] && continue
    mask="$(get_cpu_mask "$c")"
    pid="$(start_stress_process "$mask")"
    PIDS="$PIDS $pid"
    echo "[+] Started stress: PID=$pid on CPU$c (mask=$mask)"
  done

  LOG="${LOG_PREFIX}.csv"
  PHASE_LABEL="phase${PHASE_NUM}_stress_${CPU_SET}"
  RES="$(sample_power_csv "$PHASE_LABEL" "$CPU_SET" "$LOG")"

  stop_stress

  AVG_PWR="$(echo "$RES" | awk '{print $1}')"
  AVG_BATT_TEMP="$(echo "$RES" | awk '{print $2}')"
  AVG_CPU_TEMP="$(echo "$RES" | awk '{print $3}')"
  AVG_FREQS="$(echo "$RES" | cut -d' ' -f4-)"

  echo "[RESULT] Phase ${PHASE_NUM} (stress $CPU_SET): avg_power_W=$AVG_PWR | avg_batt_temp_C=$AVG_BATT_TEMP | avg_cpu_temp_C=$AVG_CPU_TEMP | $AVG_FREQS"
}

# ============================================================================
#                                  MAIN
# ============================================================================

echo ""
echo "=== Incremental Core Power Test (SHIELDED) ==="
echo "Cores to test: $CORES_TO_TEST"
echo "System core: $SYSTEM_CORE (all non-stress tasks confined here)"
echo "Duration per phase: ${DURATION_SEC}s; Sample interval: ${INTERVAL}s; Idle gap: ${IDLE_GAP}s"
echo "Initial online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
echo ""

keep_screen_on
setup_cgroups

LOG="${LOG_PREFIX}.csv"
{
  printf "timestamp_ms,phase,cpu_set,voltage_V,current_mA,power_W,batt_temp,cpu_temp"
  for c in $ALL_CORES; do printf ",freq_cpu%s" "$c"; done
  for c in $ALL_CORES; do printf ",cpu_usage_%s" "$c"; done
  printf "\n"
} > "$LOG"

PHASE=0
for core in $CORES_TO_TEST; do
  run_idle_phase $PHASE "$SYSTEM_CORE $core"
  PHASE=$((PHASE + 1))

  run_stress_phase $PHASE "$SYSTEM_CORE $core"
  PHASE=$((PHASE + 1))

  idle_gap_wait
done

echo ""
echo "=== Done ==="
echo "CSV file:"
echo "  ${LOG_PREFIX}.csv"

cleanup
echo "[*] Final online mask: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"

exit 0