#!/system/bin/sh
# Thermal Guardian Pro - Action button
# Runs when the "Action" button for this module is tapped in the manager
# app (KernelSU, KernelSU Next, APatch, ...). Prints a live status
# snapshot and restarts the guardian daemon if it died. For changing
# mode/toggles/profiles, use the WebUI instead.
#
# Output language auto-detects from the device locale (persist.sys.locale /
# ro.product.locale). Supported: id, en, es, pt, ru, zh - falls back to
# Indonesian if the device locale can't be read, English for anything else.

MODDIR=${0%/*}
DATADIR=/data/adb/thermal_guardian_pro
CONF=$DATADIR/config.conf
SNAPSHOT=$DATADIR/status.snapshot
EVENTLOG=$DATADIR/events.log

# ---------- language detection ----------
raw_locale=$(getprop persist.sys.locale 2>/dev/null)
[ -z "$raw_locale" ] && raw_locale=$(getprop ro.product.locale 2>/dev/null)
lc=$(echo "$raw_locale" | cut -d- -f1 | tr 'A-Z' 'a-z')
case "$lc" in
  id|in) LANG_CODE=id ;;
  en)    LANG_CODE=en ;;
  es)    LANG_CODE=es ;;
  pt)    LANG_CODE=pt ;;
  ru)    LANG_CODE=ru ;;
  zh)    LANG_CODE=zh ;;
  "")    LANG_CODE=id ;;   # locale unreadable - keep the module's original default
  *)     LANG_CODE=en ;;   # any other locale - fall back to English
esac

# ---------- translation table ----------
# t KEY - echoes the KEY string in $LANG_CODE (falls back to English)
t() {
  case "$1" in
    title)
      case "$LANG_CODE" in
        id) echo "Thermal Guardian Pro - Status Cepat" ;;
        es) echo "Thermal Guardian Pro - Estado Rapido" ;;
        pt) echo "Thermal Guardian Pro - Status Rapido" ;;
        ru) echo "Thermal Guardian Pro - Быстрый статус" ;;
        zh) echo "Thermal Guardian Pro - 快速状态" ;;
        *)  echo "Thermal Guardian Pro - Quick Status" ;;
      esac ;;
    daemon_label)
      case "$LANG_CODE" in
        id) echo "Daemon" ;;
        es) echo "Daemon" ;;
        pt) echo "Daemon" ;;
        ru) echo "Демон" ;;
        zh) echo "守护进程" ;;
        *)  echo "Daemon" ;;
      esac ;;
    daemon_running)
      case "$LANG_CODE" in
        id) echo "AKTIF" ;;
        es) echo "ACTIVO" ;;
        pt) echo "ATIVO" ;;
        ru) echo "АКТИВЕН" ;;
        zh) echo "运行中" ;;
        *)  echo "RUNNING" ;;
      esac ;;
    daemon_down_retry)
      case "$LANG_CODE" in
        id) echo "TIDAK JALAN - mencoba restart..." ;;
        es) echo "DETENIDO - intentando reiniciar..." ;;
        pt) echo "PARADO - tentando reiniciar..." ;;
        ru) echo "ОСТАНОВЛЕН - попытка перезапуска..." ;;
        zh) echo "未运行 - 正在尝试重启..." ;;
        *)  echo "NOT RUNNING - attempting restart..." ;;
      esac ;;
    daemon_restarted)
      case "$LANG_CODE" in
        id) echo "berhasil di-restart" ;;
        es) echo "reiniciado correctamente" ;;
        pt) echo "reiniciado com sucesso" ;;
        ru) echo "успешно перезапущен" ;;
        zh) echo "重启成功" ;;
        *)  echo "restarted successfully" ;;
      esac ;;
    daemon_restart_failed)
      case "$LANG_CODE" in
        id) echo "GAGAL start, cek" ;;
        es) echo "FALLO al iniciar, revisa" ;;
        pt) echo "FALHA ao iniciar, verifique" ;;
        ru) echo "ОШИБКА запуска, проверьте" ;;
        zh) echo "启动失败，请检查" ;;
        *)  echo "FAILED to start, check" ;;
      esac ;;
    mode_label)
      case "$LANG_CODE" in
        id) echo "Mode" ;;
        es) echo "Modo" ;;
        pt) echo "Modo" ;;
        ru) echo "Режим" ;;
        zh) echo "模式" ;;
        *)  echo "Mode" ;;
      esac ;;
    guardian_label)
      case "$LANG_CODE" in
        id) echo "Guardian aktif" ;;
        es) echo "Guardian activo" ;;
        pt) echo "Guardian ativo" ;;
        ru) echo "Guardian включен" ;;
        zh) echo "守护已启用" ;;
        *)  echo "Guardian on" ;;
      esac ;;
    soc_temp_label)
      case "$LANG_CODE" in
        id) echo "Suhu SoC" ;;
        es) echo "Temp. SoC" ;;
        pt) echo "Temp. SoC" ;;
        ru) echo "Темп. SoC" ;;
        zh) echo "SoC温度" ;;
        *)  echo "SoC Temp" ;;
      esac ;;
    limit_word)
      case "$LANG_CODE" in
        id) echo "limit" ;;
        es) echo "limite" ;;
        pt) echo "limite" ;;
        ru) echo "лимит" ;;
        zh) echo "上限" ;;
        *)  echo "limit" ;;
      esac ;;
    hardcap_word)
      case "$LANG_CODE" in
        id) echo "batas keras" ;;
        es) echo "limite duro" ;;
        pt) echo "limite rigido" ;;
        ru) echo "жёсткий предел" ;;
        zh) echo "硬上限" ;;
        *)  echo "hard cap" ;;
      esac ;;
    zone_label)
      case "$LANG_CODE" in
        id) echo "Zona acuan" ;;
        es) echo "Zona de referencia" ;;
        pt) echo "Zona de referencia" ;;
        ru) echo "Опорная зона" ;;
        zh) echo "参考区域" ;;
        *)  echo "Reference zone" ;;
      esac ;;
    batt_temp_label)
      case "$LANG_CODE" in
        id) echo "Suhu baterai" ;;
        es) echo "Temp. bateria" ;;
        pt) echo "Temp. bateria" ;;
        ru) echo "Темп. батареи" ;;
        zh) echo "电池温度" ;;
        *)  echo "Battery temp" ;;
      esac ;;
    active_profile_label)
      case "$LANG_CODE" in
        id) echo "Profil aktif" ;;
        es) echo "Perfil activo" ;;
        pt) echo "Perfil ativo" ;;
        ru) echo "Активный профиль" ;;
        zh) echo "当前配置" ;;
        *)  echo "Active profile" ;;
      esac ;;
    auto_heuristic_suffix)
      case "$LANG_CODE" in
        id) echo "otomatis/heuristik" ;;
        es) echo "automatico/heuristico" ;;
        pt) echo "automatico/heuristico" ;;
        ru) echo "авто/эвристика" ;;
        zh) echo "自动/启发式" ;;
        *)  echo "auto/heuristic" ;;
      esac ;;
    status_label)
      case "$LANG_CODE" in
        id) echo "Status" ;;
        es) echo "Estado" ;;
        pt) echo "Status" ;;
        ru) echo "Статус" ;;
        zh) echo "状态" ;;
        *)  echo "Status" ;;
      esac ;;
    state_stock)
      case "$LANG_CODE" in
        id) echo "proteksi stok" ;;
        es) echo "proteccion original" ;;
        pt) echo "protecao original" ;;
        ru) echo "штатная защита" ;;
        zh) echo "原厂保护" ;;
        *)  echo "stock protection" ;;
      esac ;;
    state_relaxed)
      case "$LANG_CODE" in
        id) echo "dilonggarkan" ;;
        es) echo "relajado" ;;
        pt) echo "relaxado" ;;
        ru) echo "ослаблено" ;;
        zh) echo "已放宽" ;;
        *)  echo "relaxed" ;;
      esac ;;
    hour_summary_label)
      case "$LANG_CODE" in
        id) echo "1 jam" ;;
        es) echo "1 hora" ;;
        pt) echo "1 hora" ;;
        ru) echo "1 час" ;;
        zh) echo "近1小时" ;;
        *)  echo "Last 1h" ;;
      esac ;;
    min_word)
      case "$LANG_CODE" in
        id) echo "min" ;;
        *)  echo "min" ;;
      esac ;;
    max_word)
      case "$LANG_CODE" in
        id) echo "maks" ;;
        *)  echo "max" ;;
      esac ;;
    relaxed_time_word)
      case "$LANG_CODE" in
        id) echo "waktu longgar" ;;
        es) echo "tiempo relajado" ;;
        pt) echo "tempo relaxado" ;;
        ru) echo "время ослабления" ;;
        zh) echo "放宽时长占比" ;;
        *)  echo "time relaxed" ;;
      esac ;;
    updated_label)
      case "$LANG_CODE" in
        id) echo "Diperbarui" ;;
        es) echo "Actualizado" ;;
        pt) echo "Atualizado" ;;
        ru) echo "Обновлено" ;;
        zh) echo "更新于" ;;
        *)  echo "Updated" ;;
      esac ;;
    no_snapshot)
      case "$LANG_CODE" in
        id) echo "Belum ada snapshot - daemon baru saja start, coba lagi sebentar." ;;
        es) echo "Aun sin datos - el daemon acaba de iniciar, intenta de nuevo en breve." ;;
        pt) echo "Ainda sem dados - o daemon acabou de iniciar, tente novamente em breve." ;;
        ru) echo "Данных пока нет - демон только что запустился, попробуйте позже." ;;
        zh) echo "暂无数据 - 守护进程刚启动，请稍后再试。" ;;
        *)  echo "No snapshot yet - daemon just started, try again shortly." ;;
      esac ;;
    recent_events_header)
      case "$LANG_CODE" in
        id) echo "kejadian terakhir" ;;
        es) echo "eventos recientes" ;;
        pt) echo "eventos recentes" ;;
        ru) echo "последних событий" ;;
        zh) echo "条最近事件" ;;
        *)  echo "recent events" ;;
      esac ;;
    no_events)
      case "$LANG_CODE" in
        id) echo "(belum ada kejadian tercatat)" ;;
        es) echo "(sin eventos registrados aun)" ;;
        pt) echo "(nenhum evento registrado ainda)" ;;
        ru) echo "(события ещё не записаны)" ;;
        zh) echo "（暂无记录事件）" ;;
        *)  echo "(no events recorded yet)" ;;
      esac ;;
    footer_hint)
      case "$LANG_CODE" in
        id) echo "Ganti mode/toggle/profil, atau paksa longgar/stok: buka WebUI modul ini." ;;
        es) echo "Para cambiar modo/ajustes/perfil, o forzar relajado/original: abre la WebUI del modulo." ;;
        pt) echo "Para trocar modo/ajustes/perfil, ou forcar relaxado/original: abra a WebUI do modulo." ;;
        ru) echo "Чтобы сменить режим/профиль или принудительно ослабить/восстановить: откройте WebUI модуля." ;;
        zh) echo "如需切换模式/开关/配置，或强制放宽/恢复：请打开本模块的WebUI。" ;;
        *)  echo "To change mode/toggle/profile, or force relax/stock: open this module's WebUI." ;;
      esac ;;
    unit_sec)  echo "s" ;;
    unit_min)  echo "m" ;;
    unit_hour) echo "h" ;;
    unit_day)  echo "d" ;;
    ago_prefix)
      case "$LANG_CODE" in
        es) echo "hace " ;;
        *)  echo "" ;;
      esac ;;
    ago_suffix)
      case "$LANG_CODE" in
        id) echo " lalu" ;;
        es) echo "" ;;
        pt) echo " atras" ;;
        ru) echo " назад" ;;
        zh) echo "前" ;;
        *)  echo " ago" ;;
      esac ;;
    *) echo "$1" ;;
  esac
}

fmt_age() {
  s=$1
  if [ "$s" -lt 60 ]; then u="$(t unit_sec)"; n=$s
  elif [ "$s" -lt 3600 ]; then u="$(t unit_min)"; n=$((s/60))
  elif [ "$s" -lt 86400 ]; then u="$(t unit_hour)"; n=$((s/3600))
  else u="$(t unit_day)"; n=$((s/86400))
  fi
  printf '%s%s%s%s' "$(t ago_prefix)" "$n" "$u" "$(t ago_suffix)"
}

line() { echo "----------------------------------------"; }

line
echo " $(t title)"
line

MODE=balanced
GUARDIAN_ENABLED=1
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

if pgrep -f "guardian.sh" >/dev/null 2>&1; then
  echo "$(t daemon_label)      : $(t daemon_running)"
else
  echo "$(t daemon_label)      : $(t daemon_down_retry)"
  mkdir -p "$DATADIR"
  ( exec setsid sh "$MODDIR/guardian.sh" >> "$DATADIR/guardian.log" 2>&1 & )
  sleep 2
  if pgrep -f "guardian.sh" >/dev/null 2>&1; then
    echo "$(t daemon_label)      : $(t daemon_restarted)"
  else
    echo "$(t daemon_label)      : $(t daemon_restart_failed) $DATADIR/guardian.log"
  fi
fi

echo "$(t mode_label)        : $MODE"
echo "$(t guardian_label) : $GUARDIAN_ENABLED"

if [ -f "$SNAPSHOT" ]; then
  gov=$(grep '^GOV_TEMP=' "$SNAPSHOT" | cut -d= -f2)
  govzone=$(grep '^GOV_ZONE=' "$SNAPSHOT" | cut -d= -f2-)
  batt=$(grep '^BATT_TEMP=' "$SNAPSHOT" | cut -d= -f2)
  safe=$(grep '^SAFE_TEMP=' "$SNAPSHOT" | cut -d= -f2)
  state=$(grep '^STATE=' "$SNAPSHOT" | cut -d= -f2)
  hard=$(grep '^HARD_MAX=' "$SNAPSHOT" | cut -d= -f2)
  activeprofile=$(grep '^ACTIVE_PROFILE=' "$SNAPSHOT" | cut -d= -f2)
  activeauto=$(grep '^ACTIVE_PROFILE_AUTO=' "$SNAPSHOT" | cut -d= -f2)
  hmin=$(grep '^HIST_MIN=' "$SNAPSHOT" | cut -d= -f2)
  hmax=$(grep '^HIST_MAX=' "$SNAPSHOT" | cut -d= -f2)
  hrel=$(grep '^HIST_RELAXED_PCT=' "$SNAPSHOT" | cut -d= -f2)
  updated=$(grep '^UPDATED=' "$SNAPSHOT" | cut -d= -f2)
  now=$(date +%s 2>/dev/null)
  age=$((now - ${updated:-0}))

  case "$state" in
    stock)   state_disp="$(t state_stock)" ;;
    relaxed) state_disp="$(t state_relaxed)" ;;
    *)       state_disp="${state:-$(t state_stock)}" ;;
  esac

  echo "$(t soc_temp_label)    : ${gov:-?}C ($(t limit_word) ${safe:-?}C, $(t hardcap_word) ${hard:-58}C)"
  echo "$(t zone_label)  : ${govzone:-?}"
  [ -n "$batt" ] && [ "$batt" != "-" ] && echo "$(t batt_temp_label): ${batt}C"
  if [ -n "$activeprofile" ]; then
    if [ "$activeauto" = "1" ]; then
      echo "$(t active_profile_label): $activeprofile ($(t auto_heuristic_suffix))"
    else
      echo "$(t active_profile_label): $activeprofile"
    fi
  fi
  echo "$(t status_label)      : $state_disp"
  echo "$(t hour_summary_label)       : $(t min_word) ${hmin:-?}C / $(t max_word) ${hmax:-?}C / ${hrel:-?}% $(t relaxed_time_word)"
  echo "$(t updated_label)  : $(fmt_age "$age")"
else
  echo "$(t no_snapshot)"
fi

# ---------- recent events, human-readable ----------
NUM_EVENTS=5
line
echo " $NUM_EVENTS $(t recent_events_header):"
line
if [ -f "$EVENTLOG" ]; then
  now=$(date +%s 2>/dev/null)
  tail -n "$NUM_EVENTS" "$EVENTLOG" | while IFS= read -r evline; do
    [ -n "$evline" ] || continue
    set -- $evline
    first="$1"
    case "$first" in
      ''|*[!0-9]*) evt_epoch="" ;;
      *) evt_epoch="$first"; shift ;;
    esac
    d="$1"
    tm="$2"
    case "$d" in
      [0-9][0-9][0-9][0-9]-*) shift 2; msg="$*" ;;
      *) msg="$evline"; d="" ;;
    esac
    tag="-"
    case "$msg" in
      *BATAS\ KERAS*|*BATERAI*|*DITOLAK*|*REJECTED*) tag="!" ;;
    esac
    age=""
    if [ -n "$now" ] && [ -n "$evt_epoch" ] && [ "$evt_epoch" != "0" ]; then
      age=$((now - evt_epoch))
    fi
    if [ -n "$age" ] && [ "$age" -ge 0 ] 2>/dev/null; then
      printf ' %s %s (%s)\n' "$tag" "$msg" "$(fmt_age "$age")"
    elif [ -n "$d" ]; then
      printf ' %s %s [%s %s]\n' "$tag" "$msg" "$d" "$tm"
    else
      printf ' %s %s\n' "$tag" "$msg"
    fi
  done
else
  echo "$(t no_events)"
fi

line
echo " $(t footer_hint)"
line
