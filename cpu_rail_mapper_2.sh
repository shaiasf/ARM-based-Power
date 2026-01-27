#!/system/bin/sh
# ==========================================================
# Read-only CPU rail logger for MediaTek Helio G99
# Compatible with EX Kernel Manager manual frequency control
# ==========================================================

# --- root elevation ---
if [ "$(id -u)" != "0" ]; then exec su -c "sh $0" "$@"; fi
set -eu
log() { echo "[$(date +%s)] $*"; }

# --- CPU freq policies ---
P0=/sys/devices/system/cpu/cpufreq/policy0   # little (A55)
P6=/sys/devices/system/cpu/cpufreq/policy6   # big (A76)

# --- Regulator selection ---
pick_regs() {
  REGS="$(ls -d /sys/class/regulator/regulator.* 2>/dev/null || true)"
  SEL=""
  for R in $REGS; do
    [ -f "$R/name" ] || continue
    NAME="$(cat "$R/name" 2>/dev/null || true)"
    case "$NAME" in
      *vproc11*|*vproc12*) SEL="$SEL
$R" ;;
    esac
  done
  echo "$SEL" | awk 'NF'
}

log "Selecting voltage rails (vproc11/vproc12)…"
SEL="$(ls -d /sys/class/regulator/regulator.* 2>/dev/null || echo '')"
[ -n "$SEL" ] || { echo "No regulators found."; exit 1; }

# --- output setup ---
OUT="/sdcard/reg_cpu_map_g99.csv"
hdr="ts,phase,cpu0_khz,cpu4_khz"
for R in $SEL; do hdr="$hdr,$(basename "$R")_uv"; done
echo "$hdr" > "$OUT"
log "Logging to $OUT"

pf() { [ -f "$1" ] && cat "$1" || echo 0; }

read_uvs() {
  local line=""
  for R in $SEL; do
    uv=$(cat "$R/microvolts" 2>/dev/null || echo 0)
    line="$line,$uv"
  done
  echo "$line"
}

log_once() {
  local phase="$1"
  TS=$(date +%s)
  F0=$(pf $P0/scaling_cur_freq)
  F6=$(pf $P6/scaling_cur_freq)
  echo "$TS,$phase,$F0,$F6$(read_uvs)" >> "$OUT"
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

# --- Phase durations ---
D_IDLE=${1:-10}
D_WORK=${2:-15}
PREP=30  # seconds to change settings manually in EXKM

# --- Phases sequence ---
countdown $PREP "Set IDLE (both clusters min freq)"
for i in $(seq 1 "$D_IDLE"); do log_once "idle"; sleep 1; done

countdown $PREP "Set LITTLE-ONLY (A55 max; A76 min)"
for i in $(seq 1 "$D_WORK"); do log_once "little"; sleep 1; done

countdown $PREP "Set BIG-ONLY (A76 max; A55 min)"
for i in $(seq 1 "$D_WORK"); do log_once "big"; sleep 1; done

countdown $PREP "Set COOL (both clusters back to min)"
for i in $(seq 1 "$D_IDLE"); do log_once "cool"; sleep 1; done

log "Done. Saved $OUT"
echo "Saved: $OUT"
