#!/system/bin/sh
# Thermal Guardian Pro - adaptive daemon
# POSIX sh only. Launched as a background loop from service.sh.
#
# Core idea (unchanged from Smart Thermal Guardian v3.x): never permanently
# disable the platform's thermal daemons. Only pause the userspace
# throttling POLICY while the chip is genuinely cool, and hand control
# back the instant it isn't. A hard, non-configurable ceiling always wins,
# no matter which mode or toggle the user has picked in the WebUI.
#
# New in Pro:
#  - daemon list covers Qualcomm/MediaTek/Samsung Exynos/Unisoc, not just
#    one OEM family, so restore_thermal() always has something correct to
#    hand control back to
#  - battery temperature is read as a second, independent safety signal -
#    if the SoC thermal-zone reporting is wrong or lagging, a hot battery
#    still forces stock protection back on
#  - optional per-app profiles: pin specific apps (e.g. a game) to a mode
#    without changing your global default
#  - optional "advanced" toggles for GPU/PPM/LMh power limiters, off by
#    default, clearly separated from the safe core toggles

DATADIR=/data/adb/thermal_guardian_pro
CONF=$DATADIR/config.conf
PROFILES=$DATADIR/profiles.conf
STATEFILE=$DATADIR/state
ACTIVEPROFILE=$DATADIR/active_profile
EVENTLOG=$DATADIR/events.log
HISTORY=$DATADIR/history.csv
MAXHIST=720          # ~1 hour at 5s polling, keeps history.csv small
MAXEVENTS=200

# Absolute safety ceilings. No mode, no WebUI toggle, no profile, no
# config value can push effective protection above these points.
HARD_MAX_SAFE_TEMP=58     # SoC governing temp, degrees C
HARD_MAX_BATTERY_TEMP=46  # battery temp, degrees C - independent trip

mkdir -p "$DATADIR" 2>/dev/null

log_event() {
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  epoch=$(date "+%s" 2>/dev/null)
  echo "${epoch:-0} $ts  $1" >> "$EVENTLOG"
  if [ -f "$EVENTLOG" ]; then
    lc=$(wc -l < "$EVENTLOG" 2>/dev/null)
    [ -n "$lc" ] && [ "$lc" -gt "$MAXEVENTS" ] 2>/dev/null && {
      tail -n "$MAXEVENTS" "$EVENTLOG" > "$EVENTLOG.tmp" 2>/dev/null
      mv "$EVENTLOG.tmp" "$EVENTLOG" 2>/dev/null
    }
  fi
}

load_config() {
  # Defaults, then override from file if present
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
  FORCE_ACTION=
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
}

# Clears FORCE_ACTION back out of config.conf after it's been honored (or
# refused) once, so it never re-fires on the next loop tick.
clear_force_action() {
  [ -f "$CONF" ] || return
  tmp="$CONF.tmp"
  grep -v '^FORCE_ACTION=' "$CONF" > "$tmp" 2>/dev/null
  echo "FORCE_ACTION=" >> "$tmp"
  mv "$tmp" "$CONF"
}

# One-pass rollup over history.csv: min/max/avg governing temp and the
# percentage of samples spent in "relaxed" state, over whatever the file
# currently retains (~1h at default 5s polling). Numbers only - this is
# what the WebUI shows instead of a chart.
compute_rollup() {
  [ -f "$HISTORY" ] || { echo "0 0 0 0"; return; }
  awk -F, '
    NR==1 { next }
    { n++; t=$2+0; if (n==1||t<mn) mn=t; if (n==1||t>mx) mx=t; sum+=t; if ($5=="relaxed") r++ }
    END {
      if (n==0) { print "0 0 0 0"; exit }
      printf "%d %d %d %d\n", mn, mx, (sum/n)+0.5, (r*100/n)+0.5
    }' "$HISTORY" 2>/dev/null
}

mode_safe_temp() {
  # $1 = mode to resolve (falls back to global MODE if empty)
  m=${1:-$MODE}
  case "$m" in
    eco) echo 44 ;;
    balanced) echo 47 ;;
    performance) echo 51 ;;
    custom)
      t=$CUSTOM_SAFE_TEMP
      [ "$t" -lt 40 ] 2>/dev/null && t=40
      [ "$t" -gt 54 ] 2>/dev/null && t=54
      echo "$t"
      ;;
    *) echo 47 ;;
  esac
}

# ---------- sensors ----------

# Zone-name substrings that are known NOT to represent CPU/GPU/SoC
# package temperature - battery, charging, RF, and similar sensors can
# legitimately run hotter (or spikier) than the actual chip while fast
# charging or on a call, and used to get counted as "governing" temp
# just because they were the single hottest zone on the device. That's
# the root cause of the "sometimes reads 70C out of nowhere" report:
# the old code took max() over every zone with no idea what each one
# physically was. We can't enumerate every CPU zone name across every
# OEM, but we CAN name the zones that are reliably NOT the chip, and
# exclude only those - so unrecognized-but-plausible names still count.
EXCLUDE_ZONE_PATTERN='batt|chg|charg|usb|conn|modem|mdm|^pa$|pa[_-]therm|pa_therm|camera|cam[_-]|flash|wifi|bt[_-]|skin|xo[_-]therm|pmic|pm8|pmi8|vbat|case[_-]|quiet|chassis|back[_-]therm|nfc|sar[_-]'

# Reads every SoC thermal zone, normalizes millidegree vs degree C,
# prints "type:tempC" lines, and echoes the max on the last line
# prefixed with GOV: (governing temp) and GOVZ: (the zone name that
# produced it) - restricted to zones that survive the exclude filter
# above, falling back to a true max-of-everything only if every zone
# on this device happens to match the exclude list (never leaving the
# daemon with no reading at all).
read_temps() {
  max=""; maxzone=""; fbmax=""; fbzone=""
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [ -f "$f" ] || continue
    zdir=$(dirname "$f")
    type=$(cat "$zdir/type" 2>/dev/null)
    raw=$(cat "$f" 2>/dev/null)
    [ -z "$raw" ] && continue
    case "$raw" in
      -*) continue ;;
      *[!0-9]*) continue ;;
    esac
    if [ "$raw" -gt 1000 ] 2>/dev/null; then
      c=$((raw / 1000))
    else
      c=$raw
    fi
    echo "$type:$c"
    if [ -z "$fbmax" ] || [ "$c" -gt "$fbmax" ] 2>/dev/null; then
      fbmax=$c; fbzone=$type
    fi
    lc=$(echo "$type" | tr 'A-Z' 'a-z')
    if ! echo "$lc" | grep -Eq "$EXCLUDE_ZONE_PATTERN" 2>/dev/null; then
      if [ -z "$max" ] || [ "$c" -gt "$max" ] 2>/dev/null; then
        max=$c; maxzone=$type
      fi
    fi
  done
  if [ -n "$max" ]; then
    echo "GOV:${max}"
    echo "GOVZ:${maxzone}"
  else
    echo "GOV:${fbmax:-0}"
    echo "GOVZ:${fbzone:-tidak diketahui}(fallback)"
  fi
}

read_battery_temp() {
  for f in /sys/class/power_supply/battery/temp /sys/class/power_supply/Battery/temp; do
    [ -f "$f" ] || continue
    raw=$(cat "$f" 2>/dev/null)
    case "$raw" in
      *[!0-9]*|"") continue ;;
    esac
    if [ "$raw" -ge 1000 ] 2>/dev/null; then
      echo $((raw / 1000)); return
    elif [ "$raw" -ge 150 ] 2>/dev/null; then
      echo $((raw / 10)); return
    else
      echo "$raw"; return
    fi
  done
  echo ""
}

# ---------- per-app profiles ----------

# profiles.conf format, one entry per line: package.name=mode
# First matching running package (top of file wins) overrides MODE for
# this loop iteration only. Nothing is written back to config.conf.
#
# When no explicit profile is running and AUTO_DETECT=1, we fall back to
# a lightweight heuristic classifier instead of requiring every game to
# be added by hand: this is NOT a machine-learning model (there's no ML
# runtime here - this is a POSIX shell daemon), it's two cheap signals
# combined - (a) the same third-party app has held the foreground for a
# few consecutive polls, and (b) the governing temperature is genuinely
# elevated while it's been there. Both together are a reasonable proxy
# for "something demanding is running" without reading per-process CPU
# stats, which is fragile to parse consistently across OEM `top`/`ps`
# builds. Once it commits to a package it stays committed - like a real
# profile - until that package leaves the foreground, so it doesn't
# flap in and out as temperature dips slightly.
FGSTREAK=$DATADIR/.fg_streak
AUTO_DETECT_STREAK=3

# Optional companion app (see /companion_app in the module repo) using the
# official AccessibilityService API - developer.android.com/guide/topics/ui/
# accessibility/service - to report the foreground package in real time,
# instead of relying only on parsing dumpsys text output which some
# OEMs/Android versions restrict or reformat. Purely additive: if the app
# isn't installed, its permission isn't granted, or its data is stale, this
# falls straight back to the original dumpsys-based detection below.
A11Y_BRIDGE_PKG=pro.thermalguardian.companion
A11Y_BRIDGE_FILE="/data/data/$A11Y_BRIDGE_PKG/files/foreground.state"
A11Y_BRIDGE_MAX_AGE=10   # seconds - beyond this the data is considered stale

resolve_foreground_pkg() {
  FG_SOURCE=dumpsys
  if [ -f "$A11Y_BRIDGE_FILE" ]; then
    b_epoch="" b_pkg=""
    read -r b_epoch b_pkg < "$A11Y_BRIDGE_FILE" 2>/dev/null
    now=$(date +%s 2>/dev/null)
    if [ -n "$b_epoch" ] && [ -n "$b_pkg" ] && [ -n "$now" ]; then
      age=$((now - b_epoch))
      if [ "$age" -ge 0 ] && [ "$age" -le "$A11Y_BRIDGE_MAX_AGE" ] 2>/dev/null; then
        FG_SOURCE=a11y
        echo "$b_pkg"
        return
      fi
    fi
  fi
  fg=$(dumpsys window 2>/dev/null | grep -m1 'mCurrentFocus' | sed -n 's/.*[ {]\([A-Za-z0-9_.]*\)\/[^}]*}.*/\1/p')
  if [ -z "$fg" ]; then
    fg=$(dumpsys activity activities 2>/dev/null | grep -m1 'mResumedActivity' | sed -n 's#.*[ {]\([A-Za-z0-9_.]*\)/[^ }]*}.*#\1#p')
  fi
  echo "$fg"
}

# Never auto-elevate the shell itself: launchers, System UI, settings,
# input methods, and other com.android.* system pieces. A real game
# package always has its own distinct, non-system package name.
is_excluded_fg() {
  case "$1" in
    "") return 0 ;;
    *launcher*|*systemui*|*inputmethod*|*.home|android|com.android.*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_active_profile() {
  ACTIVE_PROFILE_PKG=""
  ACTIVE_PROFILE_MODE=""
  ACTIVE_PROFILE_AUTO=0
  if [ -f "$PROFILES" ]; then
    while IFS='=' read -r pkg pmode || [ -n "$pkg" ]; do
      [ -z "$pkg" ] && continue
      case "$pkg" in \#*) continue ;; esac
      pmode=$(echo "$pmode" | tr -d ' \r')
      [ -z "$pmode" ] && continue
      if pidof "$pkg" >/dev/null 2>&1; then
        ACTIVE_PROFILE_PKG=$pkg
        ACTIVE_PROFILE_MODE=$pmode
        rm -f "$FGSTREAK" 2>/dev/null
        return
      fi
    done < "$PROFILES"
  fi

  [ "$AUTO_DETECT" = "1" ] || { rm -f "$FGSTREAK" 2>/dev/null; return; }

  fg=$(resolve_foreground_pkg)
  if is_excluded_fg "$fg"; then
    rm -f "$FGSTREAK" 2>/dev/null
    return
  fi

  s_pkg=""; s_count=0; s_active=0
  [ -f "$FGSTREAK" ] && read -r s_pkg s_count s_active < "$FGSTREAK" 2>/dev/null

  if [ "$fg" = "$s_pkg" ]; then
    s_count=$((s_count + 1))
  else
    s_pkg=$fg; s_count=1; s_active=0
  fi

  if [ "$s_active" != "1" ]; then
    gate=$(( $(mode_safe_temp "$MODE") - 3 ))
    if [ "$s_count" -ge "$AUTO_DETECT_STREAK" ] 2>/dev/null && [ "${gov:-0}" -ge "$gate" ] 2>/dev/null; then
      s_active=1
    fi
  fi

  echo "$s_pkg $s_count $s_active" > "$FGSTREAK"

  if [ "$s_active" = "1" ]; then
    ACTIVE_PROFILE_PKG=$s_pkg
    ACTIVE_PROFILE_MODE=performance
    ACTIVE_PROFILE_AUTO=1
  fi
}

# ---------- daemon control ----------
# Union of service names seen across Qualcomm/QTI, MediaTek, Samsung
# Exynos and Unisoc/Spreadtrum platforms, plus generic HAL 1.0/2.0
# names. `stop`/`start` on a service that doesn't exist on this device
# is a silent no-op, so it's safe to always attempt the full list rather
# than trying to guess the exact chipset.
THERMAL_SERVICES="
thermal-engine thermal-engine-v2 mi_thermald thermalloadalgod thermalloadalgo
vendor.thermal-engine vendor.mtk.thermal vendor.mtk.thermalservice
vendor.thermal-hal-2-0.mtk mtk-perf
vendor.qti.thermalservice vendor.qti.hardware.perf perfd perfserv
vendor.thermal-hal-1-0 vendor.thermal-hal-2-0
vendor.samsung.thermal sec-thermal-1-0 thermal_mnt_hal_service
sprd_thermal vendor.sprd_thermal vendor.sprd.thermalservice sensorhald connfsd
android.thermal-hal vendor.thermal-manager vendor.thermal_manager
oplus.thermal vendor.oplus.hardware.thermal oplus-thermal thermalcoolerd
vendor.vivo.hardware.thermal vivo_thermal vendor.vivo.thermal
vendor.xiaomi.hardware.thermal thermalcontrolcenter mi_thermal
vendor.asus.hardware.thermal asus-thermal vendor.sony.hardware.thermal
vendor.google.thermal thermalserviced vendor.thermalcontrol
"
# The list above is a best-effort union of names seen in the wild - it is
# NOT verified against every OEM's actual build since we don't have
# hardware to test on, but stop/start on a name that doesn't exist on
# this device is a silent no-op, so listing more names than any single
# phone needs is harmless.
#
# On top of the static list, AUTO_DISCOVER_THERMAL (default on) does a
# best-effort live scan for anything else matching "therm" that the
# static list missed - this is what makes coverage closer to "any
# Android device" rather than "the OEMs we happened to name". The
# discovered names are persisted to disk the moment they're found
# (relax time), because by restore time the daemon is already stopped
# and would no longer show up in a fresh scan to be rediscovered.
DISCOVERED_SVC_FILE="$DATADIR/.discovered_thermal_svcs"

discover_thermal_services() {
  ps -A 2>/dev/null | awk '{print $NF}' | grep -i 'therm' | grep -v -i 'widget\|settings\|launcher\|permission' | sort -u
}

# Note: logd is intentionally never touched - killing the log daemon has
# nothing to do with thermal management and only makes debugging harder.

stop_if_running() { stop "$1" 2>/dev/null; }
start_if_stopped() { start "$1" 2>/dev/null; }

# Save a sysfs node's current value once, before we change it, so
# restore_thermal() can put back the exact original instead of guessing.
save_and_write() {
  path=$1; newval=$2; savefile=$3
  [ -f "$path" ] || return
  if [ ! -f "$savefile" ]; then
    cat "$path" 2>/dev/null > "$savefile"
  fi
  printf '%s' "$newval" > "$path" 2>/dev/null
}

restore_saved() {
  path=$1; savefile=$2
  [ -f "$path" ] || return
  [ -f "$savefile" ] || return
  old=$(cat "$savefile" 2>/dev/null)
  [ -n "$old" ] && printf '%s' "$old" > "$path" 2>/dev/null
  rm -f "$savefile" 2>/dev/null
}

# Pause userspace throttling POLICY daemons only. Kernel/firmware level
# protection (OTP shutdown, hardware DVFS caps) is untouched and always
# stays active - this only pauses the OEM policy layer sitting on top.
relax_thermal() {
  [ "$DISABLE_THERMAL_ENGINE" = "1" ] && {
    for svc in $THERMAL_SERVICES; do stop_if_running "$svc"; done
    if [ "$AUTO_DISCOVER_THERMAL" = "1" ]; then
      found=$(discover_thermal_services)
      if [ -n "$found" ]; then
        echo "$found" > "$DISCOVERED_SVC_FILE"
        for svc in $found; do stop_if_running "$svc"; done
      fi
    fi
  }
  [ "$DISABLE_SCHED_BOOST" = "1" ] && {
    [ -f /proc/sys/kernel/sched_boost ] && echo 0 > /proc/sys/kernel/sched_boost 2>/dev/null
  }
  [ "$DISABLE_IOSTATS" = "1" ] && {
    for q in /sys/block/*/queue/iostats; do
      [ -f "$q" ] && echo 0 > "$q" 2>/dev/null
    done
  }
  if [ "$DISABLE_GPU_LIMITER" = "1" ]; then
    save_and_write /proc/gpufreq/gpufreq_power_limited 0 "$DATADIR/.save_gpufreq"
    save_and_write /proc/ppm/enabled 0 "$DATADIR/.save_ppm"
  fi
  if [ "$DISABLE_PPM_LMH" = "1" ]; then
    for f in /sys/kernel/debug/lmh/*/enabled; do
      [ -f "$f" ] && save_and_write "$f" 0 "$DATADIR/.save_lmh_$(basename "$(dirname "$f")")"
    done
  fi
  echo relaxed > "$STATEFILE"
}

# Undo whatever relax_thermal touched. This is the fail-safe path and
# runs unconditionally whenever we cross back above a safe threshold,
# regardless of which toggles are currently set.
restore_thermal() {
  for svc in $THERMAL_SERVICES; do start_if_stopped "$svc"; done
  if [ -f "$DISCOVERED_SVC_FILE" ]; then
    while IFS= read -r svc || [ -n "$svc" ]; do
      [ -n "$svc" ] && start_if_stopped "$svc"
    done < "$DISCOVERED_SVC_FILE"
    rm -f "$DISCOVERED_SVC_FILE" 2>/dev/null
  fi
  [ -f /proc/sys/kernel/sched_boost ] && echo 1 > /proc/sys/kernel/sched_boost 2>/dev/null
  for q in /sys/block/*/queue/iostats; do
    [ -f "$q" ] && echo 1 > "$q" 2>/dev/null
  done
  restore_saved /proc/gpufreq/gpufreq_power_limited "$DATADIR/.save_gpufreq"
  restore_saved /proc/ppm/enabled "$DATADIR/.save_ppm"
  for sf in "$DATADIR"/.save_lmh_*; do
    [ -f "$sf" ] || continue
    node=$(basename "$sf" | sed 's/^\.save_lmh_//')
    restore_saved "/sys/kernel/debug/lmh/$node/enabled" "$sf"
  done
  echo stock > "$STATEFILE"
}

apply_boot_time_props() {
  # ro. props only take effect on boot; applied once here, not per-loop.
  if [ "$DISABLE_SMART_DFPS" = "1" ]; then
    resetprop ro.vendor.dfps.enable false 2>/dev/null
    resetprop ro.vendor.smart_dfps.enable false 2>/dev/null
  fi
}

append_history() {
  ts=$(date "+%s")
  echo "$ts,$1,$2,$MODE,$3" >> "$HISTORY"
  lc=$(wc -l < "$HISTORY" 2>/dev/null)
  [ -n "$lc" ] && [ "$lc" -gt "$MAXHIST" ] 2>/dev/null && {
    tail -n "$MAXHIST" "$HISTORY" > "$HISTORY.tmp" 2>/dev/null
    mv "$HISTORY.tmp" "$HISTORY" 2>/dev/null
  }
}

main() {
  mkdir -p "$DATADIR"
  [ -f "$STATEFILE" ] || echo stock > "$STATEFILE"
  [ -f "$HISTORY" ] || echo "ts,temp_c,batt_c,mode,state" > "$HISTORY"
  load_config
  apply_boot_time_props
  log_event "guardian pro started (mode=$MODE)"

  while true; do
    load_config
    lines=$(read_temps)
    gov=$(echo "$lines" | grep '^GOV:' | cut -d: -f2)
    govzone=$(echo "$lines" | grep '^GOVZ:' | cut -d: -f2-)
    batt=$(read_battery_temp)

    if [ "$GUARDIAN_ENABLED" = "1" ]; then
      resolve_active_profile
    else
      ACTIVE_PROFILE_PKG=""; ACTIVE_PROFILE_MODE=""; ACTIVE_PROFILE_AUTO=0
    fi
    effective_mode=${ACTIVE_PROFILE_MODE:-$MODE}
    safe_temp=$(mode_safe_temp "$effective_mode")
    hysteresis=3

    prev_state=$(cat "$STATEFILE" 2>/dev/null)
    prev_profile=$(cat "$ACTIVEPROFILE" 2>/dev/null)
    rollup=$(compute_rollup)
    h_min=$(echo "$rollup" | cut -d' ' -f1)
    h_max=$(echo "$rollup" | cut -d' ' -f2)
    h_avg=$(echo "$rollup" | cut -d' ' -f3)
    h_relaxed_pct=$(echo "$rollup" | cut -d' ' -f4)

    if [ "$ACTIVE_PROFILE_PKG" != "$prev_profile" ]; then
      if [ -n "$ACTIVE_PROFILE_PKG" ]; then
        if [ "$ACTIVE_PROFILE_AUTO" = "1" ]; then
          log_event "deteksi otomatis (heuristik): $ACTIVE_PROFILE_PKG -> $ACTIVE_PROFILE_MODE"
        else
          log_event "profile aktif: $ACTIVE_PROFILE_PKG -> $ACTIVE_PROFILE_MODE"
        fi
      elif [ -n "$prev_profile" ]; then
        log_event "profile $prev_profile berakhir, kembali ke mode $MODE"
      fi
      echo "$ACTIVE_PROFILE_PKG" > "$ACTIVEPROFILE"
    fi

    # write a compact status snapshot for the WebUI to read
    {
      echo "GOV_TEMP=$gov"
      echo "GOV_ZONE=${govzone:--}"
      echo "BATT_TEMP=${batt:--}"
      echo "MODE=$MODE"
      echo "EFFECTIVE_MODE=$effective_mode"
      echo "ACTIVE_PROFILE=$ACTIVE_PROFILE_PKG"
      echo "ACTIVE_PROFILE_AUTO=$ACTIVE_PROFILE_AUTO"
      echo "FG_SOURCE=${FG_SOURCE:-dumpsys}"
      echo "SAFE_TEMP=$safe_temp"
      echo "HYSTERESIS=$hysteresis"
      echo "STATE=$prev_state"
      echo "HARD_MAX=$HARD_MAX_SAFE_TEMP"
      echo "HARD_MAX_BATT=$HARD_MAX_BATTERY_TEMP"
      echo "HIST_MIN=$h_min"
      echo "HIST_MAX=$h_max"
      echo "HIST_AVG=$h_avg"
      echo "HIST_RELAXED_PCT=$h_relaxed_pct"
      echo "UPDATED=$(date "+%s")"
      echo "$lines" | grep -v '^GOV:' | grep -v '^GOVZ:'
    } > "$DATADIR/status.snapshot.tmp"
    mv "$DATADIR/status.snapshot.tmp" "$DATADIR/status.snapshot"

    if [ "$GUARDIAN_ENABLED" = "1" ]; then
      batt_trip=0
      [ -n "$batt" ] && [ "$batt" -ge "$HARD_MAX_BATTERY_TEMP" ] 2>/dev/null && batt_trip=1
      hard_trip=0
      [ "$gov" -ge "$HARD_MAX_SAFE_TEMP" ] 2>/dev/null && hard_trip=1

      # Manual force request from the WebUI/action button. Still bounded
      # by both hard ceilings - a force-relax request is refused (and
      # logged as refused) if the device is already at/over either limit.
      if [ -n "$FORCE_ACTION" ]; then
        case "$FORCE_ACTION" in
          restore)
            [ "$prev_state" != "stock" ] && restore_thermal && log_event "restore paksa dari WebUI"
            prev_state=stock
            ;;
          relax)
            if [ "$batt_trip" = "1" ] || [ "$hard_trip" = "1" ]; then
              log_event "relax paksa DITOLAK - suhu masih di/atas batas keras"
            elif [ "$prev_state" != "relaxed" ]; then
              relax_thermal
              log_event "relax paksa dari WebUI"
              prev_state=relaxed
            fi
            ;;
        esac
        clear_force_action
      fi

      if [ "$batt_trip" = "1" ]; then
        if [ "$prev_state" != "stock" ]; then
          restore_thermal
          log_event "BATERAI ${batt}C >= ${HARD_MAX_BATTERY_TEMP}C - proteksi stok dipaksa aktif"
        fi
      elif [ "$hard_trip" = "1" ]; then
        if [ "$prev_state" != "stock" ]; then
          restore_thermal
          log_event "BATAS KERAS ${gov}C >= ${HARD_MAX_SAFE_TEMP}C - proteksi stok dipaksa aktif"
        fi
      elif [ "$gov" -ge "$safe_temp" ] 2>/dev/null; then
        if [ "$prev_state" != "stock" ]; then
          restore_thermal
          log_event "${gov}C mencapai batas aman ${safe_temp}C ($effective_mode) - proteksi stok dipulihkan"
        fi
      else
        low_water=$((safe_temp - hysteresis))
        if [ "$gov" -le "$low_water" ] 2>/dev/null && [ "$prev_state" != "relaxed" ]; then
          relax_thermal
          log_event "${gov}C aman di bawah ${low_water}C - limit dilonggarkan ($effective_mode)"
        fi
      fi
    else
      [ -n "$FORCE_ACTION" ] && clear_force_action
      if [ "$prev_state" != "stock" ]; then
        restore_thermal
        log_event "guardian dimatikan pengguna - proteksi stok dipulihkan"
      fi
    fi

    append_history "$gov" "${batt:-0}" "$(cat "$STATEFILE" 2>/dev/null)"
    sleep "${POLL_INTERVAL:-5}"
  done
}

main
