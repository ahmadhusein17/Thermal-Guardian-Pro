ui_print "- Menginstal Thermal Guardian Pro..."

ui_print "======================================"
ui_print "  Model   : $(getprop ro.product.model)"
ui_print "  Chipset : $(getprop ro.board.platform) / $(getprop ro.hardware)"
ui_print "  Android : $(getprop ro.build.version.release)"
ui_print "======================================"

ui_print "- Mengatur hak akses skrip..."
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/action.sh 0 0 0755
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/guardian.sh 0 0 0755
set_perm $MODPATH/webui_bridge.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755

# $KSU / $KSU_VER / $KSU_VER_CODE / $KSU_KERNEL_VER_CODE only exist as
# env vars right here, during customize.sh - the WebUI bridge runs long
# after boot as an ad-hoc root exec with no access to install-time env,
# so we cache them once now for the WebUI's "Perangkat" (device info)
# tab to read later. Never overwrite a value with blank on module
# update if for some reason a var isn't set this time around.
DATADIR=/data/adb/thermal_guardian_pro
DEVICEINFO_CACHE=$DATADIR/device_info.conf
mkdir -p "$DATADIR" 2>/dev/null
if [ "$KSU" = "true" ]; then
  ROOT_SOLUTION_DETECTED="KernelSU"
elif [ -d /data/adb/ap ]; then
  ROOT_SOLUTION_DETECTED="APatch"
elif [ -d /data/adb/magisk ]; then
  ROOT_SOLUTION_DETECTED="Magisk"
else
  ROOT_SOLUTION_DETECTED="Tidak diketahui"
fi
cat > "$DEVICEINFO_CACHE" <<EOF
ROOT_SOLUTION=$ROOT_SOLUTION_DETECTED
KSU_VER=$KSU_VER
KSU_VER_CODE=$KSU_VER_CODE
KSU_KERNEL_VER_CODE=$KSU_KERNEL_VER_CODE
INSTALL_ARCH=$ARCH
INSTALL_API=$API
EOF

ui_print "- Modul ini TIDAK menimpa binary thermal manapun secara permanen."
ui_print "- Semua kontrol lewat daemon adaptif dengan batas keras 58C (SoC)"
ui_print "  dan 46C (baterai) yang tidak bisa dimatikan dari mode manapun."
ui_print "- Buka WebUI modul ini di manager untuk atur mode, toggle, dan"
ui_print "  profil per-aplikasi."
ui_print "- Instalasi selesai!"
