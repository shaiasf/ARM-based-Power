#!/system/bin/sh
# cpu_rails_logger_live.sh — log & display battery + per-cluster regulator data
# Usage: sh cpu_rails_logger_live.sh

LOG="/data/local/tmp/cpu_rails_log.csv"
DURATION_SEC=600      # 10 minutes
INTERVAL_SEC=0.5

echo "timestamp_ms,Vbatt_uV,Ibatt_uA,L_v_uV,L_i_uA,B_v_uV,B_i_uA,P_v_uV,P_i_uA" > "$LOG"
echo "[*] Logging to $LOG for ${DURATION_SEC}s (Ctrl+C to stop early)..."
echo ""

END_TIME=$(( $(date +%s) + DURATION_SEC ))

while [ $(date +%s) -lt $END_TIME ]; do
  TS=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s)*1000 )))
  VB=$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null)
  IB=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  Lv=$(cat /sys/class/regulator/regulator.51/microvolts 2>/dev/null)
  Li=$(cat /sys/class/regulator/regulator.51/microamps  2>/dev/null)
  Bv=$(cat /sys/class/regulator/regulator.50/microvolts 2>/dev/null)
  Bi=$(cat /sys/class/regulator/regulator.50/microamps  2>/dev/null)
  Pv=$(cat /sys/class/regulator/regulator.49/microvolts 2>/dev/null)
  Pi=$(cat /sys/class/regulator/regulator.49/microamps  2>/dev/null)

  echo "$TS,$VB,$IB,$Lv,$Li,$Bv,$Bi,$Pv,$Pi" >> "$LOG"

  # --- live print to terminal ---
  printf "Vb=%7dµV  Ib=%8dµA | L:(%7dµV,%8dµA)  B:(%7dµV,%8dµA)  P:(%7dµV,%8dµA)\r" \
    "$VB" "$IB" "$Lv" "$Li" "$Bv" "$Bi" "$Pv" "$Pi"

  sleep "$INTERVAL_SEC"
done

echo ""
echo "[*] Done. File saved at $LOG"
