#!/usr/bin/env bash
# per_core_scaling_all_stress.sh — Measure idle and stressed power at min/max frequencies
# Phases:
#   1. Idle at Minimum Frequency
#   2. Idle at Maximum Frequency
#   3. Stress at Minimum Frequency
#   4. Stress at Maximum Frequency
#
# Requires: root (sudo), cpupower, taskset (optional), RAPL or powerstat (optional)

set -euo pipefail
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] Run with: sudo $0"
  exit 1
fi

# ===== Config =====
MIN_FREQ="1.2GHz"
MAX_FREQ="3.6GHz"
DURATION_SEC="${1:-600}"
INTERVAL_SEC="${2:-1}"
IDLE_GAP_SEC="${3:-0}"
CSV_OUT="entire_cpu_power.csv"
DEVICE_NAME="$(hostname)"
CPUS=("0" "1" "2" "3")
# ===================

log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" >&2; }
need(){ command -v "$1" >/dev/null 2>&1; }

# --- Frequency pinning ---
pin_min(){
  cpupower --cpu all frequency-set -d "$MIN_FREQ" -u "$MIN_FREQ" >/dev/null
  cpupower --cpu all frequency-set -g powersave >/dev/null
  sleep 2
}
pin_max(){
  cpupower --cpu all frequency-set -d "$MAX_FREQ" -u "$MAX_FREQ" >/dev/null
  cpupower --cpu all frequency-set -g performance >/dev/null
  sleep 2
}

# --- Power measurement (RAPL preferred) ---
find_rapl_energy(){
  for r in /sys/class/powercap/intel-rapl/intel-rapl:*; do
    [[ -f "$r/name" && "$(cat "$r/name")" == "package-0" ]] && { echo "$r/energy_uj"; return 0; }
  done; return 1
}
avg_power_w(){
  local efile
  if efile=$(find_rapl_energy); then
    local e1 t1 e2 t2
    e1=$(cat "$efile"); t1=$(date +%s.%N)
    sleep "$DURATION_SEC"
    e2=$(cat "$efile"); t2=$(date +%s.%N)
    awk -v e1="$e1" -v e2="$e2" -v t1="$t1" -v t2="$t2" 'BEGIN{
      maxv=281474976710656; dE=e2-e1; if(dE<0)dE+=maxv; dt=t2-t1;
      printf("%.6f\n",(dE/dt)/1e6);
    }'
  elif need powerstat; then
    local tmp; tmp=$(mktemp)
    powerstat -R 1 "$DURATION_SEC" >"$tmp" 2>&1 || true
    awk '/Average/ {for(i=NF;i>=1;i--) if($i ~ /^[0-9]+\.[0-9]+$/){printf("%.6f\n",$i+0); exit}}' "$tmp" || echo "0"
    rm -f "$tmp"
  else
    log "WARNING: No RAPL/powerstat available; reporting 0."
    echo "0"
  fi
}

# --- Helpers ---

read_cpu_usage() {
  # Reads /proc/stat twice to compute CPU utilization per core (over INTERVAL_SEC)
  local interval="${1:-1}"
  local -n usage_arr=$2  # pass by reference
  local tmp1 tmp2

  tmp1=$(mktemp)
  tmp2=$(mktemp)

  grep "^cpu[0-9]" /proc/stat > "$tmp1"
  sleep "$interval"
  grep "^cpu[0-9]" /proc/stat > "$tmp2"

  while read -r line1 && read -r line2 <&3; do
    c1=($line1); c2=($line2)
    total1=$((c1[1]+c1[2]+c1[3]+c1[4]+c1[5]+c1[6]+c1[7]))
    total2=$((c2[1]+c2[2]+c2[3]+c2[4]+c2[5]+c2[6]+c2[7]))
    idle1=${c1[4]}; idle2=${c2[4]}
    diff_total=$((total2-total1))
    diff_idle=$((idle2-idle1))
    util=$(awk -v dt="$diff_total" -v di="$diff_idle" 'BEGIN{if(dt>0)printf("%.1f",100*(1-di/dt));else print 0}')
    usage_arr+=("$util")
  done 3<"$tmp2" <"$tmp1"

  rm -f "$tmp1" "$tmp2"
}


idle_gap(){ [[ "$IDLE_GAP_SEC" -gt 0 ]] && { log "[Idle gap] ${IDLE_GAP_SEC}s"; sleep "$IDLE_GAP_SEC"; } || true; }

cpu_temp(){
  awk '{printf("%.1f",$1/1000)}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0
}



# cpu_voltage(){
#   local sum=0 n=0
#   for c in "${CPUS[@]}"; do
#     if rdmsr -p "$c" 0x198 >/dev/null 2>&1; then
#       vid_hex=$(rdmsr -p "$c" 0x198)
#       vid_dec=$((0x${vid_hex} & 0xFFFF))
#       volt=$(awk -v vid="$vid_dec" 'BEGIN{printf("%.3f", vid/8192)}')
#       sum=$(awk -v a="$sum" -v b="$volt" 'BEGIN{printf("%.6f", a+b)}')
#       n=$((n+1))
#     fi
#   done
#   if [[ $n -gt 0 ]]; then
#     awk -v s="$sum" -v n="$n" 'BEGIN{printf("%.3f", s/n)}'
#   else
#     echo 0
#   fi
# }


cpu_voltage() {
  local sum=0 n=0

  for c in "${CPUS[@]}"; do
    # Check if rdmsr works on this core
    if sudo rdmsr -p "$c" 0x198 >/dev/null 2>&1; then
      # Extract VID bits 47:32 and convert to volts
      volt=$(echo "scale=3; $(sudo rdmsr -p "$c" 0x198 -u --bitfield 47:32) / 8192" | bc)

      # Accumulate
      sum=$(echo "scale=6; $sum + $volt" | bc)
      n=$((n+1))
    fi
  done

  # Return average voltage
  if [[ $n -gt 0 ]]; then
    echo "scale=3; $sum / $n" | bc
  else
    echo 0
  fi
}


cpu_usage_all(){
  mpstat -P ALL 1 1 | awk '/[0-9]+\.[0-9]+/ && $3 != "CPU" {printf("%.1f ",100-$12)}' 2>/dev/null || echo "0 0 0 0"
}

# --- Stress control ---
start_stress(){
  stop_stress
  for cpu in "${CPUS[@]}"; do
    yes >/dev/null & disown
  done
}
stop_stress(){ pkill -f "^yes$" >/dev/null 2>&1 || true; }

# --- Phase measurement ---
measure_phase(){
  local phase="$1" corner="$2" stress="$3"

  # --- Set frequency and governor ---
  if [[ "$corner" == "min" ]]; then
    pin_min; gov="powersave-pinned-min"
  else
    pin_max; gov="performance-pinned-max"
  fi

  log "[Phase=$phase | Corner=$corner | Stress=$stress] Running for ${DURATION_SEC}s"

  [[ "$stress" == "on" ]] && start_stress || stop_stress

  # --- Energy measurement start ---
  local efile=$(find_rapl_energy)
  local E_start=$(cat "$efile" 2>/dev/null || echo 0)
  local T_start=$(date +%s.%N)

  # --- Accumulators ---
  local n=0 sum_temp=0 sum_volt=0
  declare -a sum_freq cnt sum_usage

  local start_ts=$(date +%s)
  local end_ts=$((start_ts + DURATION_SEC))

  while [[ $(date +%s) -lt $end_ts ]]; do
    ts=$(date +%s)

    # --- Temperature ---
    temp=$(cpu_temp)

    # --- Voltage (MSR-based average) ---
    volt=$(cpu_voltage)

    # --- Frequencies ---
    freqs=""
    for c in "${CPUS[@]}"; do
      f_file="/sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq"
      f_val=$(cat "$f_file" 2>/dev/null || echo 0)
      freqs="${freqs},${f_val}"
      sum_freq[$c]=$(( ${sum_freq[$c]:-0} + f_val ))
      cnt[$c]=$(( ${cnt[$c]:-0} + 1 ))
    done

    # --- CPU usage (read from /proc/stat) ---
    declare -a usage_vals=()
    read_cpu_usage "$INTERVAL_SEC" usage_vals

    usages=""
    for i in "${!CPUS[@]}"; do
      u_val="${usage_vals[$i]:-0}"
      usages="${usages},${u_val}"
      sum_usage[$i]=$(awk -v s="${sum_usage[$i]:-0}" -v u="$u_val" 'BEGIN{printf("%.6f",s+u)}')
    done

    # --- Accumulate averages ---
    sum_temp=$(awk -v s="$sum_temp" -v v="$temp" 'BEGIN{printf("%.6f",s+v)}')
    sum_volt=$(awk -v s="$sum_volt" -v v="$volt" 'BEGIN{printf("%.6f",s+v)}')
    n=$((n+1))

    # --- Log sample ---
    echo "$ts,$phase,$corner,,${temp},${volt}${freqs}${usages}" >> "$CSV_OUT"
  done

  [[ "$stress" == "on" ]] && stop_stress

  # --- Energy measurement end ---
  local E_end=$(cat "$efile" 2>/dev/null || echo 0)
  local Duration=$(awk -v s="$T_start" -v e="$(date +%s.%N)" 'BEGIN{printf("%.6f", e-s)}')
  local Energy_J=$(awk -v e1="$E_start" -v e2="$E_end" 'BEGIN{maxv=281474976710656; d=e2-e1; if(d<0)d+=maxv; printf("%.6f", d/1e6)}')
  local AvgPwr=$(awk -v E="$Energy_J" -v t="$Duration" 'BEGIN{if(t>0)printf("%.6f",E/t);else print 0}')

  # --- Compute averages ---
  avg_temp=$(awk -v s="$sum_temp" -v n="$n" 'BEGIN{printf("%.1f",s/n)}')
  avg_volt=$(awk -v s="$sum_volt" -v n="$n" 'BEGIN{printf("%.3f",s/n)}')

  avg_freqs=""; avg_usages=""
  for c in "${CPUS[@]}"; do
    avg_freqs="${avg_freqs},$(awk -v s="${sum_freq[$c]:-0}" -v n="${cnt[$c]:-1}" 'BEGIN{if(n>0)printf("%.0f",s/n);else print 0}')"
    avg_usages="${avg_usages},$(awk -v s="${sum_usage[$c]:-0}" -v n="${cnt[$c]:-1}" 'BEGIN{if(n>0)printf("%.1f",s/n);else print 0}')"
  done

  echo "SUMMARY,$phase,$corner,$AvgPwr,$avg_temp,$avg_volt${avg_freqs}${avg_usages}" >> "$CSV_OUT"
  log "[SUMMARY] Phase=$phase | Corner=$corner | Avg Power=${AvgPwr}W | Temp=${avg_temp}°C | Volt=${avg_volt}V"
}

# --- Main ---
main(){
  echo "timestamp,Phase,Corner,AveragePower_W,cpu_temp,cpu_voltage,freq_cpu0,freq_cpu1,freq_cpu2,freq_cpu3,usage_cpu0,usage_cpu1,usage_cpu2,usage_cpu3" > "$CSV_OUT"

  measure_phase "idle_min" "min" "off"
  idle_gap
  measure_phase "idle_max" "max" "off"
  idle_gap
  measure_phase "stress_min" "min" "on"
  idle_gap
  measure_phase "stress_max" "max" "on"

  log "Done → $CSV_OUT"
}
trap 'stop_stress' INT TERM EXIT
main "$@"
