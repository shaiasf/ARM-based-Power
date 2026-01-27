#!/system/bin/sh
# Read-only CPU rail logger for Pixel 8 Pro (Tensor G3)
# 30-second prep timer between phases — no writes to cpufreq.

if [ "$(id -u)" != "0" ]; then exec su -c "sh $0" "$@"; fi
set -eu
log() { echo "[$(date +%s)] $*"; }

pick_regs() {
  REGS="$(ls -d \
    /sys/devices/platform/acpm_mfd_bus@15500000/i2c-1/1-001f/s2mpg14-regulator/regulator/regulator.* 2>/dev/null; \
    ls -d /sys/devices/platform/acpm_mfd_bus@15510000/i2c-0/0-002f/s2mpg15-regulator/regulator/regulator.* 2>/dev/null || true)"
  SEL=""
  for R in $REGS; do
    [ -f "$R/name" ] || continue
    NAME="$(cat "$R/name" 2>/dev/null || true)"
    echo "$NAME" | grep -qi "BUCK" || continue
    case "$NAME" in *BUCKA*|*BUCKD*|*BUCKBOOST*) continue ;; esac
    MAX=$(cat "$R/max_microvolts" 2>/dev/null || echo 0)
    MIN=$(cat "$R/min_microvolts" 2>/dev/null || echo 0)
    [ "$MAX" -gt 0 ] || continue
    if [ "$MAX" -le 1500000 ] && [ "$MIN" -ge 300000 ]; then
      SEL="$SEL
$R"
    fi
  done
  echo "$SEL" | awk 'NF'
}

pf() { [ -f "$1" ] && cat "$1" || echo 0; }

P0=/sys/devices/system/cpu/cpufreq/policy0
P4=/sys/devices/system/cpu/cpufreq/policy4
P7=/sys/devices/system/cpu/cpufreq/policy7

log "Selecting regulators (read-only)…"
SEL="$(pick_regs)"
[ -n "$SEL" ] || { echo "No candidate BUCKs found"; exit 1; }

OUT="/sdcard/reg_cpu_map.csv"
hdr="ts,phase,cpu0_khz,cpu4_khz,cpu7_khz"
for R in $SEL; do hdr="$hdr,$(basename "$R")_uv"; done
echo "$hdr" > "$OUT"
log "Logging to $OUT"

read_uvs() {
  line=""
  for R in $SEL; do
    uv=$(cat "$R/microvolts" 2>/dev/null || echo 0)
    line="$line,$uv"
  done
  echo "$line"
}

log_once() {
  phase="$1"
  TS=$(date +%s)
  F0=$(pf $P0/scaling_cur_freq)
  F4=$(pf $P4/scaling_cur_freq)
  F7=$(pf $P7/scaling_cur_freq)
  echo "$TS,$phase,$F0,$F4,$F7$(read_uvs)" >> "$OUT"
}

countdown() {
  secs="$1"; msg="$2"
  log "$msg"
  while [ "$secs" -gt 0 ]; do
    printf "\r→ %s: starting in %2ds " "$msg" "$secs"
    secs=$((secs-1))
    sleep 1
  done
  echo
}

# Phase durations
D_IDLE=${1:-10}
D_WORK=${2:-15}
PREP=30   # preparation delay before each phase

countdown $PREP "Set IDLE in EXKM (all clusters min)"
for i in $(seq 1 "$D_IDLE"); do log_once "idle"; sleep 1; done

countdown $PREP "Set LITTLE-ONLY (little max; big/prime min)"
for i in $(seq 1 "$D_WORK"); do log_once "little"; sleep 1; done

countdown $PREP "Set BIG-ONLY (big max; others min)"
for i in $(seq 1 "$D_WORK"); do log_once "big"; sleep 1; done

countdown $PREP "Set PRIME-ONLY (prime max; others min)"
for i in $(seq 1 "$D_WORK"); do log_once "prime"; sleep 1; done

countdown $PREP "Set COOL (all min)"
for i in $(seq 1 "$D_IDLE"); do log_once "cool"; sleep 1; done

log "Done. Saved $OUT"
echo "Saved: $OUT"
