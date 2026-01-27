#!/system/bin/sh
# Preheat CPU until target temperature is reached.
# Usage: sh cpu_preheat_until_temp.sh [target_temp_C] [core_id] [interval_s]
# Example: sh cpu_preheat_until_temp.sh 50 0 2

TARGET="${1:-50}"
CORE="${2:-0}"
INTERVAL="${3:-2}"

echo "[+] Target temperature: ${TARGET}°C"
echo "[+] Using core: ${CORE}"
echo "[+] Poll interval: ${INTERVAL}s"

# Try common SoC temp paths
TEMP_PATHS="
/sys/class/thermal/thermal_zone0/temp
/sys/class/thermal/thermal_zone1/temp
/sys/devices/virtual/thermal/thermal_zone0/temp
"
for path in $TEMP_PATHS; do
    if [ -r "$path" ]; then
        TEMP_PATH="$path"
        break
    fi
done

if [ -z "$TEMP_PATH" ]; then
    echo "[!] No readable thermal path found!"
    exit 1
fi

# Start stressing (background)
echo "[+] Starting CPU stress on core $CORE..."
taskset -c "$CORE" yes >/dev/null 2>&1 &
STRESS_PID=$!

# Monitor temperature
while true; do
    RAW=$(cat "$TEMP_PATH" 2>/dev/null)
    [ "$RAW" -gt 1000 ] && TEMP=$(awk "BEGIN{printf \"%.1f\", $RAW/1000}") || TEMP="$RAW"

    echo "[*] Current: ${TEMP}°C"
    if [ "$(awk "BEGIN{print ($TEMP >= $TARGET)}")" -eq 1 ]; then
        echo "[✓] Target ${TARGET}°C reached. Stopping stress."
        kill "$STRESS_PID" >/dev/null 2>&1
        break
    fi

    sleep "$INTERVAL"
done

# Verify
sleep 2
RAW=$(cat "$TEMP_PATH" 2>/dev/null)
[ "$RAW" -gt 1000 ] && TEMP=$(awk "BEGIN{printf \"%.1f\", $RAW/1000}") || TEMP="$RAW"
echo "[*] Final temperature: ${TEMP}°C"
echo "[✓] CPU preheat complete."
