#!/system/bin/sh
# Stop the guardian daemon and restore stock thermal daemons immediately,
# without waiting for reboot. Config/history files under $DATADIR are
# intentionally left in place so a reinstall picks up your old settings.

DATADIR=/data/adb/thermal_guardian_pro

pkill -f "guardian.sh" 2>/dev/null

for svc in thermal-engine thermal-engine-v2 mi_thermald thermalloadalgod thermalloadalgo \
  vendor.thermal-engine vendor.mtk.thermal vendor.mtk.thermalservice vendor.thermal-hal-2-0.mtk mtk-perf \
  vendor.qti.thermalservice vendor.qti.hardware.perf perfd perfserv \
  vendor.thermal-hal-1-0 vendor.thermal-hal-2-0 \
  vendor.samsung.thermal sec-thermal-1-0 thermal_mnt_hal_service \
  sprd_thermal vendor.sprd_thermal vendor.sprd.thermalservice sensorhald connfsd \
  android.thermal-hal vendor.thermal-manager vendor.thermal_manager; do
  start "$svc" 2>/dev/null
done

[ -f /proc/sys/kernel/sched_boost ] && echo 1 > /proc/sys/kernel/sched_boost 2>/dev/null
for q in /sys/block/*/queue/iostats; do
  [ -f "$q" ] && echo 1 > "$q" 2>/dev/null
done
[ -f "$DATADIR/.save_gpufreq" ] && cat "$DATADIR/.save_gpufreq" > /proc/gpufreq/gpufreq_power_limited 2>/dev/null
[ -f "$DATADIR/.save_ppm" ] && cat "$DATADIR/.save_ppm" > /proc/ppm/enabled 2>/dev/null

echo stock > "$DATADIR/state" 2>/dev/null
