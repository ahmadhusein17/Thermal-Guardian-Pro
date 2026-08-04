#!/system/bin/sh
# Thermal Guardian Pro - boot entrypoint
# Runs in the late_start service context (Magisk/KernelSU/APatch all
# source service.sh the same way). Just launches the guardian daemon in
# the background and gets out of the way - guardian.sh itself waits for
# nothing and is safe to start early.

MODDIR=${0%/*}
DATADIR=/data/adb/thermal_guardian_pro

mkdir -p "$DATADIR" 2>/dev/null

# Give the boot animation / early services a moment before we start
# touching thermal daemons, purely cosmetic - guardian.sh's own logic
# is what keeps things safe, not this delay.
( 
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 1
  done
  exec setsid sh "$MODDIR/guardian.sh" >> "$DATADIR/guardian.log" 2>&1
) &
