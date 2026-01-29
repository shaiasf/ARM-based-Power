#!/system/bin/sh
# ==========================================================
# Universal CPU Rail Voltage Logger
# Compatible with manual frequency control (e.g., EX Kernel Manager)
# Logs CPU frequencies and voltage regulator readings
# ==========================================================

# --- root elevation ---
if [ "$(id -u)" != "0" ]; then exec su -c "sh $0" "$@"; fi
set -eu
log() { echo "[$(date +%s)] $*"; }

# ============================================================================
#                           INTERACTIVE CONFIGURATION
# ============================================================================

echo "======================================================================"
echo "              Universal CPU Rail Voltage Logger"
echo "======================================================================"
echo ""
echo "This script logs CPU frequencies and voltage regulator readings."
echo "You will manually change CPU frequencies during the test."
echo ""

# Get CPU policy paths
echo "Enter CPU policy numbers (space-separated, e.g., 0 6):"
echo "(Usually policy0 for little cores, policy6 for big cores)"
read POLICIES
POLICIES="${POLICIES:-0 6}"

# Convert to policy paths
POLICY_PATHS=""
for p in $POLICIES; do
  POLICY_PATHS="$POLICY_PATHS /sys/devices/system/cpu/cpufreq/policy${p}"
done

# Get regulator name patterns
echo ""
echo "Enter regulator name patterns to match (space-separated, e.g., vproc11 vproc12):"
echo "(Leave empty to scan all regulators)"
read REG_PATTERNS
REG_PATTERNS="${REG_PATTERNS:-vproc11 vproc12}"

# Get phase durations
echo ""
echo "Enter idle phase duration in seconds (default: 10):"
read D_IDLE
D_IDLE="${D_IDLE:-10}"

echo ""
echo "Enter workload phase duration in seconds (default: 15):"
read D_WORK
D_WORK="${D_WORK:-15}"

echo ""
echo "Enter preparation time between phases in seconds (default: 30):"
echo "(Time given to manually change frequencies in your kernel manager)"
read PREP
PREP="${PREP:-30}"

# Get output location
echo ""
echo "Enter output file path (default: /sdcard/reg_cpu_map.csv):"
read OUT
OUT="${OUT:-/sdcard/reg_cpu_map.csv}"

# Display configuration
echo ""
echo "======================================================================"
echo "                      CONFIGURATION SUMMARY"
echo "======================================================================"
echo "CPU policies:         $POLICIES"
echo "Regulator patterns:   $REG_PATTERNS"
echo "Idle duration:        ${D_IDLE}s"
echo "Work duration:        ${D_WORK}s"
echo "Prep time:            ${PREP}s"
echo "Output file:          $OUT"
echo "======================================================================"
echo ""
echo "Test phases:"
echo "  1. IDLE    - All clusters at minimum frequency (${D_IDLE}s)"
echo "  2. FIRST   - First cluster max, others min (${D_WORK}s)"
echo "  3. SECOND  - Second cluster max, others min (${D_WORK}s)"
echo "  4. COOL    - All clusters back to minimum (${D_IDLE}s)"
echo ""
echo "You will have ${PREP}s between each phase to manually adjust"
echo "frequencies in your kernel manager app (e.g., EX Kernel Manager)."
echo "======================================================================"
echo ""
echo "Press ENTER to continue or Ctrl+C to cancel..."
read CONFIRM

# ============================================================================
#                           REGULATOR SELECTION
# ============================================================================

pick_regs() {
  REGS="$(ls -d /sys/class/regulator/regulator.* 2>/dev/null || true)"
  SEL=""

  if [ -z "$REG_PATTERNS" ]; then
    # No pattern specified, use all regulators
    SEL="$REGS"
  else
    # Match patterns
    for R in $REGS; do
      [ -f "$R/name" ] || continue
      NAME="$(cat "$R/name" 2>/dev/null || true)"

      for PATTERN in $REG_PATTERNS; do
        case "$NAME" in
          *$PATTERN*) SEL="$SEL
$R"
          break
          ;;
        esac
      done
    done
  fi

  echo "$SEL" | awk 'NF'
}

log "Selecting voltage rails matching: $REG_PATTERNS"
SEL="$(pick_regs)"

if [ -z "$SEL" ]; then
  log "No matching regulators found!"
  echo ""
  echo "Available regulators:"
  for R in $(ls -d /sys/class/regulator/regulator.* 2>/dev/null || true); do
    if [ -f "$R/name" ]; then
      echo "  $(basename "$R"): $(cat "$R/name" 2>/dev/null || echo 'unknown')"
    fi
  done
  exit 1
fi

log "Selected regulators:"
for R in $SEL; do
  NAME="$(cat "$R/name" 2>/dev/null || echo 'unknown')"
  log "  $(basename "$R"): $NAME"
done

# ============================================================================
#                           OUTPUT SETUP
# ============================================================================

# Create CSV header
hdr="ts,phase"
for p in $POLICIES; do
  hdr="$hdr,policy${p}_khz"
done
for R in $SEL; do
  hdr="$hdr,$(basename "$R")_uv"
done

echo "$hdr" > "$OUT"
log "Logging to $OUT"

# ============================================================================
#                           HELPER FUNCTIONS
# ============================================================================

pf() { [ -f "$1" ] && cat "$1" 2>/dev/null || echo 0; }

read_freqs() {
  local line=""
  for path in $POLICY_PATHS; do
    freq=$(pf "$path/scaling_cur_freq")
    line="$line,$freq"
  done
  echo "$line"
}

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
  echo "$TS,$phase$(read_freqs)$(read_uvs)" >> "$OUT"
}

countdown() {
  secs="$1"
  msg="$2"
  log "$msg"
  while [ "$secs" -gt 0 ]; do
    printf "\r→ %s: starting in %2ds " "$msg" "$secs"
    secs=$((secs-1))
    sleep 1
  done
  echo
}

# ============================================================================
#                           PHASE INSTRUCTIONS
# ============================================================================

echo ""
echo "======================================================================"
echo "                      MANUAL SETUP INSTRUCTIONS"
echo "======================================================================"
echo ""
echo "During each countdown, you need to manually set frequencies:"
echo ""
echo "Phase 1 - IDLE:"
echo "  → Set ALL clusters to MINIMUM frequency"
echo ""
echo "Phase 2 - FIRST CLUSTER ONLY:"
policy_num=$(echo "$POLICIES" | awk '{print $1}')
echo "  → Set policy${policy_num} (first cluster) to MAXIMUM frequency"
echo "  → Set all other policies to MINIMUM frequency"
echo ""
echo "Phase 3 - SECOND CLUSTER ONLY:"
policy_num=$(echo "$POLICIES" | awk '{print $2}')
if [ -n "$policy_num" ]; then
  echo "  → Set policy${policy_num} (second cluster) to MAXIMUM frequency"
  echo "  → Set all other policies to MINIMUM frequency"
else
  echo "  → (No second cluster configured, will skip)"
fi
echo ""
echo "Phase 4 - COOL DOWN:"
echo "  → Set ALL clusters back to MINIMUM frequency"
echo ""
echo "======================================================================"
echo ""
echo "Press ENTER when ready to start..."
read READY

# ============================================================================
#                           PHASES SEQUENCE
# ============================================================================

# Phase 1: IDLE
countdown $PREP "Phase 1: Set IDLE (all clusters min freq)"
log "Phase 1: Logging IDLE for ${D_IDLE}s..."
for i in $(seq 1 "$D_IDLE"); do
  log_once "idle"
  sleep 1
done

# Phase 2: FIRST CLUSTER
first_policy=$(echo "$POLICIES" | awk '{print $1}')
countdown $PREP "Phase 2: Set FIRST CLUSTER (policy${first_policy} max; others min)"
log "Phase 2: Logging FIRST CLUSTER for ${D_WORK}s..."
for i in $(seq 1 "$D_WORK"); do
  log_once "first"
  sleep 1
done

# Phase 3: SECOND CLUSTER (if exists)
second_policy=$(echo "$POLICIES" | awk '{print $2}')
if [ -n "$second_policy" ]; then
  countdown $PREP "Phase 3: Set SECOND CLUSTER (policy${second_policy} max; others min)"
  log "Phase 3: Logging SECOND CLUSTER for ${D_WORK}s..."
  for i in $(seq 1 "$D_WORK"); do
    log_once "second"
    sleep 1
  done
else
  log "Skipping Phase 3: No second cluster configured"
fi

# Phase 4: COOL
countdown $PREP "Phase 4: Set COOL (all clusters back to min)"
log "Phase 4: Logging COOL for ${D_IDLE}s..."
for i in $(seq 1 "$D_IDLE"); do
  log_once "cool"
  sleep 1
done

# ============================================================================
#                           COMPLETION
# ============================================================================

log "Done. Saved $OUT"
echo ""
echo "======================================================================"
echo "                      TEST COMPLETE"
echo "======================================================================"
echo "Output saved to: $OUT"
echo ""
echo "You can now analyze the data to map frequencies to voltages."
echo "======================================================================"

exit 0