#!/system/bin/sh
# big_cluster_power.sh – Three-phase power test for BIG cluster:
# Phase 0: Only CPU0 online, idle (baseline)
# Phase 1: All BIG cores online, idle (no stress)
# Phase 2: All BIG cores online, stressed
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
  LOG_PREFIX="$OUT_DIR/big_core_power_${MINMAX}"
else
  LOG_PREFIX="$OUT_DIR/big_core_power"
fi

mkdir -p "$OUT_DIR"

# --- Config ---
ALL_CORES="0 1 2 3 4 5 6 7 8"   # Adjust if your device has different topology
BIG_CORES="4 5 6 7"             # Define BIG cluster cores (to be tested)
HOUSEKEEPING_CORES="0"          # Housekeeping core (stays online but idle)

# ---- Sanity checks ---------------------------------------------------------
command -v yes >/dev/null 2>&1 || { echo "[!] 'yes' not found"; exit 1; }
command -v taskset >/dev/null 2>&1 || { echo "[!] 'taskset' not found"; exit 1; }
id | grep -q "uid=0" || { echo "[!] Run as root (su)"; exit 1; }

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

# Battery voltage in microvolts (uV)
read_v_uV() {
  if [ -r /sys/class/power_supply/battery/voltage_now ]; then
    cat /sys/class/power_supply/battery/voltage_now 2>/dev/null
  else
    MV="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *voltage/ {print $2; exit}')"
    [ -n "$MV" ] || MV=0
    echo $(( MV * 1000 ))
  fi
}

# Battery current in microamps (uA). Use abs so power is positive.
read_i_uA() {
  if   [ -r /sys/class/power_supply/battery/current_now ]; then I="$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)"
  elif [ -r /sys/class/power_supply/battery/current_avg ]; then I="$(cat /sys/class/power_supply/battery/current_avg 2>/dev/null)"
  else I="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /current now/ {print $3; exit}')"
  fi
  [ -n "$I" ] || I=0
  case "$I" in -*) I="${I#-}";; esac
  echo "$I"
}

# Battery temperature in °C
read_batt_temp() {
  local raw=""
  if [ -r /sys/class/power_supply/battery/temp ]; then
    raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null)"
  else
    raw="$(dumpsys battery 2>/dev/null | awk 'tolower($0) ~ /^ *temperature/ {print $2; exit}')"
  fi
  [ -n "$raw" ] || raw=0
  local abs_raw="${raw#-}"
  local C
  if [ "$abs_raw" -ge 1000 ]; then
    C="$(awk -v x="$raw" 'BEGIN{printf("%.1f", x/1000.0)}')"
  else
    C="$(awk -v x="$raw" 'BEGIN{printf("%.1f", x/10.0)}')"
  fi
  echo "$C"
}

# CPU temperature in °C (thermal_zone2)
read_cpu_temp() {
  local raw=0
  if [ -r /sys/class/thermal/thermal_zone2/temp ]; then
    raw="$(cat /sys/class/thermal/thermal_zone2/temp 2>/dev/null)"
  fi
  [ -n "$raw" ] || raw=0
  awk -v x="$raw" 'BEGIN{printf("%.1f", x/1000.0)}'
}

# CPU online/offline
set_cpu_online() {
  cpu="$1"; val="$2"
  f="/sys/devices/system/cpu/cpu$cpu/online"
  if [ -e "$f" ]; then echo "$val" > "$f" 2>/dev/null || true; fi
}

cpu_is_online() {
  cpu="$1"
  f="/sys/devices/system/cpu/cpu$cpu/online"
  if [ ! -e "$f" ]; then
    # cpu0 often lacks 'online' → treat as online
    [ "$cpu" = "0" ] && echo 1 && return
  fi
  if [ -r "$f" ]; then
    cat "$f"
  else
    echo 0
  fi
}

# Read per-core current frequency in Hz; print "offline" if offline or missing
read_freq_hz_or_offline() {
  cpu="$1"
  if [ "$(cpu_is_online "$cpu")" != "1" ]; then
    echo "offline"
    return
  fi
  f="/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq"
  if [ -r "$f" ]; then
    khz="$(cat "$f" 2>/dev/null)"
    if [ -n "$khz" ] && [ "$khz" -gt 0 ] 2>/dev/null; then
      awk -v k="$khz" 'BEGIN{printf("%.0f", k*1000.0)}'   # Hz
    else
      echo "0"
    fi
  else
    echo "0"
  fi
}

# Calculate per-core CPU usage from two /proc/stat snapshots
# Call this ONCE per sample iteration with previous and current snapshots
calc_cpu_usage_pct() {
  cpu="$1"
  prev_stat="$2"
  curr_stat="$3"
  
  if [ "$(cpu_is_online "$cpu")" != "1" ]; then
    echo "offline"
    return
  fi
  
  # Get cpu line for this core from both snapshots
  prev_line="$(echo "$prev_stat" | sed -n "s/^cpu${cpu} //p")"
  curr_line="$(echo "$curr_stat" | sed -n "s/^cpu${cpu} //p")"
  
  if [ -z "$prev_line" ] || [ -z "$curr_line" ]; then
    echo "0"
    return
  fi
  
  # Extract user, nice, system, idle, iowait, irq, softirq from both
  prev_user=$(echo "$prev_line" | awk '{print $1}'); curr_user=$(echo "$curr_line" | awk '{print $1}')
  prev_nice=$(echo "$prev_line" | awk '{print $2}'); curr_nice=$(echo "$curr_line" | awk '{print $2}')
  prev_system=$(echo "$prev_line" | awk '{print $3}'); curr_system=$(echo "$curr_line" | awk '{print $3}')
  prev_idle=$(echo "$prev_line" | awk '{print $4}'); curr_idle=$(echo "$curr_line" | awk '{print $4}')
  prev_iowait=$(echo "$prev_line" | awk '{print $5}'); curr_iowait=$(echo "$curr_line" | awk '{print $5}')
  prev_irq=$(echo "$prev_line" | awk '{print $6}'); curr_irq=$(echo "$curr_line" | awk '{print $6}')
  prev_softirq=$(echo "$prev_line" | awk '{print $7}'); curr_softirq=$(echo "$curr_line" | awk '{print $7}')
  
  # Calculate deltas
  d_user=$((curr_user - prev_user))
  d_nice=$((curr_nice - prev_nice))
  d_system=$((curr_system - prev_system))
  d_idle=$((curr_idle - prev_idle))
  d_iowait=$((curr_iowait - prev_iowait))
  d_irq=$((curr_irq - prev_irq))
  d_softirq=$((curr_softirq - prev_softirq))
  
  # Calculate usage percentage from delta
  d_total=$((d_user + d_nice + d_system + d_idle + d_iowait + d_irq + d_softirq))
  if [ "$d_total" -eq 0 ]; then
    echo "0"
  else
    d_work=$((d_total - d_idle))
    pct=$(awk -v w="$d_work" -v t="$d_total" 'BEGIN{printf("%.1f", (w/t)*100)}')
    echo "$pct"
  fi
}

# Start yes pinned to mask in THIS shell; return PID
start_yes_mask() {
  mask="$1"
  taskset "$mask" yes >/dev/null &
  echo $!
}

stop_yes() { pkill yes >/dev/null 2>&1 || true; }

cleanup() {
  echo ""
  echo "[*] Cleaning up: killing yes, restoring all cores online"
  stop_yes
  release_screen_lock
  for c in $ALL_CORES; do set_cpu_online "$c" 1; done
  echo "[*] Online mask now: $(cat /sys/devices/system/cpu/online 2>/dev/null || echo 'unknown')"
}
trap cleanup INT TERM

# Sample loop: prints CSV and echoes averages via stdout at end
sample_power_csv() {
  LABEL="$1"; CPU_SET="$2"; LOG="$3"

  printf "\n" >> "$LOG"

  # Take initial /proc/stat snapshot for delta calculations
  PROC_STAT_PREV="$(cat /proc/stat 2>/dev/null)"

  START="$(now_ms)"
  while : ; do
    NOW="$(now_ms)"
    ELAPSED=$(( NOW - START ))
    [ "$ELAPSED" -ge $(( DURATION_SEC * 1000 )) ] && break

    V_uV="$(read_v_uV)"
    I_uA="$(read_i_uA)"
    BATT_TEMP="$(read_batt_temp)"
    CPU_TEMP="$(read_cpu_temp)"
    
    # Take current /proc/stat snapshot for CPU usage calculation
    PROC_STAT_CURR="$(cat /proc/stat 2>/dev/null)"

    # Build one CSV row
    {
      awk -v ts="$(now_ms)" -v ph="$LABEL" -v cpus="$CPU_SET" -v V="$V_uV" -v I="$I_uA" -v BT="$BATT_TEMP" -v CT="$CPU_TEMP" '
        BEGIN {
          Vv = V/1000000.0; Im = I/1000.0; Pw = (V*I)/1e12;
          printf("%s,%s,%s,%.3f,%.3f,%.6f,%.1f,%.1f",
                ts, ph, cpus, Vv, Im, Pw, BT, CT);
        }'
      for c in $ALL_CORES; do
        val="$(read_freq_hz_or_offline "$c")"
        printf ",%s" "$val"
      done
      for c in $ALL_CORES; do
        cpu_usage="$(calc_cpu_usage_pct "$c" "$PROC_STAT_PREV" "$PROC_STAT_CURR")"
        printf ",%s" "$cpu_usage"
      done
      printf "\n"
    } >> "$LOG"

    # Update previous snapshot for next iteration
    PROC_STAT_PREV="$PROC_STAT_CURR"

    sleep "$INTERVAL" 2>/dev/null || sleep 1
  done

  # Compute averages for THIS PHASE only
  AVG_PWR="$(awk -F, -v ph="$LABEL" '$2==ph && $6 ~ /^[0-9.]+$/ {sum+=$6; n++} END {if(n>0) printf("%.6f", sum/n); else print "0"}' "$LOG")"
  AVG_BATT_TEMP="$(awk -F, -v ph="$LABEL" '$2==ph && $7 ~ /^[0-9.]+$/ {sum+=$7; n++} END {if(n>0) printf("%.1f", sum/n); else print "0.0"}' "$LOG")"
  AVG_CPU_TEMP="$(awk -F, -v ph="$LABEL" '$2==ph && $8 ~ /^[0-9.]+$/ {sum+=$8; n++} END {if(n>0) printf("%.1f", sum/n); else print "0.0"}' "$LOG")"

  # Per-core average frequencies for cores in CPU_SET
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

  # Append summary row to CSV
  SUMMARY_TS="$(now_ms)"
  {
    printf "%s,SUMMARY,%s,,,%.6f,%.1f,%.1f" "$SUMMARY_TS" "$LABEL" "$AVG_PWR" "$AVG_BATT_TEMP" "$AVG_CPU_TEMP"
    # append per-core avg freqs for each core in ALL_CORES
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

  echo "[SUMMARY] Phase=$LABEL | corner=${MINMAX:-NA} | Avg Power=${AVG_PWR} W | Avg BattTemp=${AVG_BATT_TEMP}°C | Avg CPUTemp=${AVG_CPU_TEMP}°C"
  echo "$AVG_PWR $AVG_BATT_TEMP $AVG_CPU_TEMP $AVG_FREQ_REPORT"
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
  echo "[+] Phase 1 (idle): BIG cores (4-7) online idle, CPU0 housekeeping online idle"

  # Bring all BIG cores online
  for c in $BIG_CORES; do
    set_cpu_online "$c" 1
  done

  # Bring housekeeping core online
  for c in $HOUSEKEEPING_CORES; do
    set_cpu_online "$c" 1
  done

  # Turn off all other cores (not in BIG_CORES or HOUSEKEEPING_CORES)
  for c in $ALL_CORES; do
    if ! echo "$BIG_CORES $HOUSEKEEPING_CORES" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done
  
  # No stress applied - all cores idle

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
  echo "[+] Phase 2 (stress): BIG cores (4-7) online and stressed, CPU0 housekeeping online idle"

  # Ensure all BIG cores are online
  for c in $BIG_CORES; do
    set_cpu_online "$c" 1
  done
  
  # Ensure housekeeping core is online (but will NOT be stressed)
  for c in $HOUSEKEEPING_CORES; do
    set_cpu_online "$c" 1
  done

  # Ensure all other cores remain off
  for c in $ALL_CORES; do
    if ! echo "$BIG_CORES $HOUSEKEEPING_CORES" | grep -qw "$c"; then
      set_cpu_online "$c" 0
    fi
  done

  # Start stress ONLY on BIG cores (4-7), NOT on housekeeping core (0)
  PIDS=""
  for c in $BIG_CORES; do
    case "$c" in
      4) mask="10" ;;
      5) mask="20" ;;
      6) mask="40" ;;
      7) mask="80" ;;
      *) mask=$((1 << c)) ;;
    esac
    PID="$(start_yes_mask "$mask")"
    PIDS="$PIDS $PID"
    echo "[+] Started yes stress: PID=$PID on CPU$c (mask=$mask)"
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

# ---- Run sequence ----------------------------------------------------------
echo "=== BIG Cluster Power Test ==="
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
