#!/system/bin/sh
# Thermal Guardian Pro - WebUI bridge
# Invoked by the WebUI via the root exec bridge, e.g.:
#   sh /data/adb/modules/thermal_guardian_pro/webui_bridge.sh status
# Every command prints a single line of compact JSON on success.

DATADIR=/data/adb/thermal_guardian_pro
CONF=$DATADIR/config.conf
PROFILES=$DATADIR/profiles.conf
STATEFILE=$DATADIR/state
EVENTLOG=$DATADIR/events.log
HISTORY=$DATADIR/history.csv
SNAPSHOT=$DATADIR/status.snapshot

mkdir -p "$DATADIR" 2>/dev/null

# guardian.sh now prefixes each events.log line with a unix-epoch field
# (for action.sh's relative-time display). Strip it back off here so the
# WebUI's event list keeps showing exactly "YYYY-MM-DD HH:MM:SS  message"
# like before, whether or not the line has the new epoch prefix.
strip_epoch() {
  case "$1" in
    [0-9]*\ [0-9][0-9][0-9][0-9]-*) echo "${1#* }" ;;
    *) echo "$1" ;;
  esac
}

default_config() {
  cat > "$CONF" <<EOF
MODE=balanced
CUSTOM_SAFE_TEMP=47
POLL_INTERVAL=5
GUARDIAN_ENABLED=1
DISABLE_THERMAL_ENGINE=1
DISABLE_SCHED_BOOST=1
DISABLE_IOSTATS=0
DISABLE_SMART_DFPS=0
DISABLE_GPU_LIMITER=0
DISABLE_PPM_LMH=0
AUTO_DISCOVER_THERMAL=1
AUTO_DETECT=1
THEME=dark
LANG_UI=id
FORCE_ACTION=
EOF
}

[ -f "$CONF" ] || default_config
[ -f "$PROFILES" ] || : > "$PROFILES"

esc() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

detect_chipset() {
  board=$(getprop ro.board.platform 2>/dev/null)
  hw=$(getprop ro.hardware 2>/dev/null)
  case "$board$hw" in
    *mt*|*mediatek*) echo "MediaTek" ;;
    *exynos*) echo "Samsung Exynos" ;;
    *gs101*|*gs201*|*gs301*|*tensor*) echo "Google Tensor" ;;
    *sprd*|*ums*|*unisoc*) echo "Unisoc" ;;
    *qcom*|*msm*|*sm*|*kona*|*lahaina*|*taro*) echo "Qualcomm" ;;
    *) echo "Tidak diketahui" ;;
  esac
}

# Device/root info is fetched once when a tab is opened, never as part
# of the recurring poll loop - none of this changes while the phone is
# running, so there is no reason to pay for it every 6-30s like temp/
# state do. KSU_VER/KSU_VER_CODE/KSU_KERNEL_VER_CODE/ROOT_SOLUTION are
# only reliably available as env vars during customize.sh at install
# time (per KernelSU's own module guide) so those are cached to
# $DEVICEINFO_CACHE once by customize.sh; everything else here is read
# live since getprop/uname always work regardless of calling context.
DEVICEINFO_CACHE=$DATADIR/device_info.conf

cmd_device_info() {
  MODDIR=$(dirname "$0")
  ROOT_SOLUTION=""; KSU_VER=""; KSU_VER_CODE=""; KSU_KERNEL_VER_CODE=""
  [ -f "$DEVICEINFO_CACHE" ] && . "$DEVICEINFO_CACHE" 2>/dev/null
  if [ -z "$ROOT_SOLUTION" ]; then
    if [ -d /data/adb/ksu ]; then ROOT_SOLUTION="KernelSU"
    elif [ -d /data/adb/ap ]; then ROOT_SOLUTION="APatch"
    elif [ -d /data/adb/magisk ]; then ROOT_SOLUTION="Magisk"
    else ROOT_SOLUTION="Tidak diketahui"
    fi
  fi
  modver=$(grep '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2-)
  android_rel=$(getprop ro.build.version.release 2>/dev/null)
  android_sdk=$(getprop ro.build.version.sdk 2>/dev/null)
  kernel=$(uname -r 2>/dev/null)
  arch=$(uname -m 2>/dev/null)
  model=$(getprop ro.product.model 2>/dev/null)
  manuf=$(getprop ro.product.manufacturer 2>/dev/null)
  printf '{"android_release":"%s","android_sdk":"%s","kernel":"%s","arch":"%s","model":"%s","manufacturer":"%s","chipset":"%s","module_version":"%s","root_solution":"%s","ksu_ver":"%s","ksu_ver_code":"%s","ksu_kernel_ver_code":"%s"}\n' \
    "$(esc "${android_rel:-?}")" "$(esc "${android_sdk:-?}")" "$(esc "${kernel:-?}")" "$(esc "${arch:-?}")" \
    "$(esc "${model:-?}")" "$(esc "${manuf:-?}")" "$(esc "$(detect_chipset)")" "$(esc "${modver:-?}")" \
    "$(esc "$ROOT_SOLUTION")" "$(esc "$KSU_VER")" "$(esc "$KSU_VER_CODE")" "$(esc "$KSU_KERNEL_VER_CODE")"
}

# Backend for the Game tab's app picker. Lists installed 3rd-party
# packages and flags the ones found in the module's bundled gamelist.txt
# (just a helpful sort/badge hint, not a requirement - any package can
# still be added as a profile by typing it in, known or not).
GAMELIST_FILE_DEFAULT="$(dirname "$0")/gamelist.txt"

cmd_installed_apps() {
  glist="$GAMELIST_FILE_DEFAULT"
  printf '['
  first=1
  pm list packages -3 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      package:*) pkg=${line#package:} ;;
      *) continue ;;
    esac
    pkg=$(echo "$pkg" | tr -d '\r')
    [ -z "$pkg" ] && continue
    isgame=false
    if [ -f "$glist" ] && grep -Fxq "$pkg" "$glist" 2>/dev/null; then
      isgame=true
    fi
    [ "$first" = 1 ] || printf ','
    printf '{"pkg":"%s","known_game":%s}' "$(esc "$pkg")" "$isgame"
    first=0
  done
  printf ']\n'
}

cmd_status() {
  [ -f "$CONF" ] && . "$CONF"
  gov=0; govzone="-"; batt=""; safe=0; hyst=3; state=stock; hard=58; hardbatt=46; updated=0
  effmode=""; activeprofile=""; activeauto=0; hmin=0; hmax=0; havg=0; hrel=0
  zones=""
  if [ -f "$SNAPSHOT" ]; then
    while IFS= read -r line; do
      case "$line" in
        GOV_TEMP=*) gov=${line#GOV_TEMP=} ;;
        GOV_ZONE=*) govzone=${line#GOV_ZONE=} ;;
        BATT_TEMP=*) batt=${line#BATT_TEMP=} ;;
        EFFECTIVE_MODE=*) effmode=${line#EFFECTIVE_MODE=} ;;
        ACTIVE_PROFILE=*) activeprofile=${line#ACTIVE_PROFILE=} ;;
        ACTIVE_PROFILE_AUTO=*) activeauto=${line#ACTIVE_PROFILE_AUTO=} ;;
        SAFE_TEMP=*) safe=${line#SAFE_TEMP=} ;;
        HYSTERESIS=*) hyst=${line#HYSTERESIS=} ;;
        STATE=*) state=${line#STATE=} ;;
        HARD_MAX=*) hard=${line#HARD_MAX=} ;;
        HARD_MAX_BATT=*) hardbatt=${line#HARD_MAX_BATT=} ;;
        HIST_MIN=*) hmin=${line#HIST_MIN=} ;;
        HIST_MAX=*) hmax=${line#HIST_MAX=} ;;
        HIST_AVG=*) havg=${line#HIST_AVG=} ;;
        HIST_RELAXED_PCT=*) hrel=${line#HIST_RELAXED_PCT=} ;;
        UPDATED=*) updated=${line#UPDATED=} ;;
        MODE=*) : ;;
        *:*)
          z=$(echo "$line" | cut -d: -f1)
          v=$(echo "$line" | cut -d: -f2)
          [ -n "$zones" ] && zones="$zones,"
          zones="$zones{\"zone\":\"$(esc "$z")\",\"c\":$v}"
          ;;
      esac
    done < "$SNAPSHOT"
  fi
  [ "$batt" = "-" ] && batt=""
  running=0
  pgrep -f "guardian.sh" >/dev/null 2>&1 && running=1
  if [ "$running" = "0" ]; then
    MODDIR=$(dirname "$0")
    ( exec setsid sh "$MODDIR/guardian.sh" >> "$DATADIR/guardian.log" 2>&1 & )
  fi
  printf '{"governing_c":%s,"governing_zone":"%s","battery_c":%s,"safe_temp":%s,"hysteresis":%s,"state":"%s","hard_max":%s,"hard_max_battery":%s,"updated":%s,"mode":"%s","effective_mode":"%s","active_profile":"%s","active_profile_auto":%s,"daemon_running":%s,"guardian_enabled":%s,"custom_safe_temp":%s,"poll_interval":%s,"disable_thermal_engine":%s,"disable_sched_boost":%s,"disable_iostats":%s,"disable_smart_dfps":%s,"disable_gpu_limiter":%s,"disable_ppm_lmh":%s,"auto_detect":%s,"auto_discover_thermal":%s,"theme":"%s","lang":"%s","chipset":"%s","hist_min":%s,"hist_max":%s,"hist_avg":%s,"hist_relaxed_pct":%s,"zones":[%s]}\n' \
    "${gov:-0}" "$(esc "${govzone:--}")" "${batt:-null}" "${safe:-0}" "${hyst:-3}" "$(esc "${state:-stock}")" "${hard:-58}" "${hardbatt:-46}" "${updated:-0}" \
    "$(esc "${MODE:-balanced}")" "$(esc "${effmode:-${MODE:-balanced}}")" "$(esc "$activeprofile")" "${activeauto:-0}" "$running" \
    "${GUARDIAN_ENABLED:-1}" "${CUSTOM_SAFE_TEMP:-47}" "${POLL_INTERVAL:-5}" \
    "${DISABLE_THERMAL_ENGINE:-1}" "${DISABLE_SCHED_BOOST:-1}" "${DISABLE_IOSTATS:-0}" "${DISABLE_SMART_DFPS:-0}" \
    "${DISABLE_GPU_LIMITER:-0}" "${DISABLE_PPM_LMH:-0}" "${AUTO_DETECT:-1}" "${AUTO_DISCOVER_THERMAL:-1}" \
    "$(esc "${THEME:-dark}")" "$(esc "${LANG_UI:-id}")" \
    "$(esc "$(detect_chipset)")" "${hmin:-0}" "${hmax:-0}" "${havg:-0}" "${hrel:-0}" "$zones"
}

cmd_set() {
  key=$1; val=$2
  [ -f "$CONF" ] || default_config
  tmp="$CONF.tmp"
  grep -v "^${key}=" "$CONF" > "$tmp" 2>/dev/null
  echo "${key}=${val}" >> "$tmp"
  mv "$tmp" "$CONF"
  printf '{"ok":true}\n'
}

cmd_reset() {
  default_config
  printf '{"ok":true}\n'
}

cmd_events() {
  n=${1:-50}
  printf '['
  first=1
  if [ -f "$EVENTLOG" ]; then
    tail -n "$n" "$EVENTLOG" | while IFS= read -r line; do
      [ "$first" = 1 ] || printf ','
      printf '"%s"' "$(esc "$(strip_epoch "$line")")"
      first=0
    done
  fi
  printf ']\n'
}

cmd_history() {
  n=${1:-120}
  printf '['
  first=1
  if [ -f "$HISTORY" ]; then
    tail -n "$n" "$HISTORY" | grep -v '^ts,' | while IFS=, read -r ts temp battc mode state; do
      [ -n "$ts" ] || continue
      [ "$first" = 1 ] || printf ','
      printf '{"ts":%s,"temp_c":%s,"batt_c":%s,"mode":"%s","state":"%s"}' "$ts" "${temp:-0}" "${battc:-0}" "$(esc "$mode")" "$(esc "$state")"
      first=0
    done
  fi
  printf ']\n'
}

cmd_profiles() {
  printf '['
  first=1
  if [ -f "$PROFILES" ]; then
    while IFS='=' read -r pkg pmode || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      case "$pkg" in \#*) continue ;; esac
      pmode=$(echo "$pmode" | tr -d ' \r')
      [ -z "$pmode" ] && continue
      [ "$first" = 1 ] || printf ','
      printf '{"pkg":"%s","mode":"%s"}' "$(esc "$pkg")" "$(esc "$pmode")"
      first=0
    done < "$PROFILES"
  fi
  printf ']\n'
}

cmd_profile_set() {
  pkg=$1; pmode=$2
  [ -z "$pkg" ] && { printf '{"error":"paket kosong"}\n'; return; }
  [ -f "$PROFILES" ] || : > "$PROFILES"
  tmp="$PROFILES.tmp"
  grep -v "^${pkg}=" "$PROFILES" > "$tmp" 2>/dev/null
  echo "${pkg}=${pmode}" >> "$tmp"
  mv "$tmp" "$PROFILES"
  printf '{"ok":true}\n'
}

cmd_profile_remove() {
  pkg=$1
  [ -f "$PROFILES" ] || { printf '{"ok":true}\n'; return; }
  tmp="$PROFILES.tmp"
  grep -v "^${pkg}=" "$PROFILES" > "$tmp" 2>/dev/null
  mv "$tmp" "$PROFILES"
  printf '{"ok":true}\n'
}

cmd_events_raw() {
  n=${1:-30}
  printf '['
  first=1
  if [ -f "$EVENTLOG" ]; then
    tail -n "$n" "$EVENTLOG" | while IFS= read -r line; do
      [ "$first" = 1 ] || printf ','
      printf '"%s"' "$(esc "$(strip_epoch "$line")")"
      first=0
    done
  fi
  printf ']'
}

cmd_profiles_raw() {
  printf '['
  first=1
  if [ -f "$PROFILES" ]; then
    while IFS='=' read -r pkg pmode || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      case "$pkg" in \#*) continue ;; esac
      pmode=$(echo "$pmode" | tr -d ' \r')
      [ -z "$pmode" ] && continue
      [ "$first" = 1 ] || printf ','
      printf '{"pkg":"%s","mode":"%s"}' "$(esc "$pkg")" "$(esc "$pmode")"
      first=0
    done < "$PROFILES"
  fi
  printf ']'
}

# Single round-trip for the main WebUI loop: status + recent events +
# profile list in one shell invocation instead of three. This is the
# command the poll loop and the mode/toggle handlers use.
cmd_poll() {
  printf '{"status":'
  cmd_status | tr -d '\n'
  printf ',"events":'
  cmd_events_raw 30
  printf ',"profiles":'
  cmd_profiles_raw
  printf '}\n'
}

# set + poll in one call, so pressing a button is a single round trip
# instead of "set" followed by a separate "status" fetch.
cmd_apply() {
  key=$1; val=$2
  [ -n "$key" ] && cmd_set "$key" "$val" >/dev/null
  cmd_poll
}

cmd_force() {
  case "$1" in
    relax|restore) cmd_apply FORCE_ACTION "$1" ;;
    *) printf '{"error":"aksi tidak dikenal"}\n' ;;
  esac
}

cmd_restart_daemon() {
  MODDIR=$(dirname "$0")
  if ! pgrep -f "guardian.sh" >/dev/null 2>&1; then
    ( exec setsid sh "$MODDIR/guardian.sh" >> "$DATADIR/guardian.log" 2>&1 & )
    sleep 1
  fi
  running=0
  pgrep -f "guardian.sh" >/dev/null 2>&1 && running=1
  printf '{"ok":true,"running":%s}\n' "$running"
}

cmd_debug() {
  echo "== proses =="
  pgrep -af "guardian.sh" 2>/dev/null
  ps 2>/dev/null | grep "guardian.sh" | grep -v grep
  echo "== isi $DATADIR =="
  ls -la "$DATADIR" 2>&1
  echo "== state =="
  cat "$DATADIR/state" 2>&1
  echo "== 20 baris terakhir guardian.log =="
  tail -20 "$DATADIR/guardian.log" 2>&1
  echo "== 5 baris terakhir events.log =="
  tail -5 "$EVENTLOG" 2>&1
  echo "== jumlah baris history.csv =="
  wc -l "$HISTORY" 2>&1
}

case "$1" in
  status) cmd_status ;;
  poll) cmd_poll ;;
  apply) cmd_apply "$2" "$3" ;;
  force) cmd_force "$2" ;;
  set) cmd_set "$2" "$3" ;;
  reset) cmd_reset ;;
  events) cmd_events "$2" ;;
  history) cmd_history "$2" ;;
  profiles) cmd_profiles ;;
  profile_set) cmd_profile_set "$2" "$3" ;;
  profile_remove) cmd_profile_remove "$2" ;;
  device_info) cmd_device_info ;;
  installed_apps) cmd_installed_apps ;;
  restart_daemon) cmd_restart_daemon ;;
  debug) cmd_debug ;;
  *) printf '{"error":"unknown command"}\n' ;;
esac
