#!/system/bin/sh

LOG="/data/local/tmp/tems_autostart.log"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

PKG="com.tems.pocket"
ACT="com.tems.applications.TcMainActivity"

# coords
ANR_WAIT_X=720
ANR_WAIT_Y=1850

RECOVER_YES_X=900
RECOVER_YES_Y=1240

is_powered() {
  dumpsys battery | grep -qE "AC powered: true|USB powered: true|Wireless powered: true|powered: true"
}

is_pocket_resumed() {
  dumpsys activity activities | grep -qE "topResumedActivity=.*${PKG}/.*${ACT}|ResumedActivity:.*${PKG}/.*${ACT}"
}

current_focus_line() {
  dumpsys window windows 2>/dev/null | grep -m 1 "mCurrentFocus="
}

has_anr() {
  dumpsys window windows 2>/dev/null | grep -qiE \
    "Application Not Responding|Not Responding|isn't responding|isnt responding|ANR"
}

# --- popup clicking (reliable) ---
_last_yes_ts=0
maybe_tap_yes_recover() {
  now="$(date +%s)"
  # once per 3 seconds max
  if [ $((now - _last_yes_ts)) -lt 3 ]; then
    return 0
  fi

  _last_yes_ts="$now"
  focus="$(current_focus_line)"
  log "tap YES (recover) at ${RECOVER_YES_X},${RECOVER_YES_Y} (focus=${focus:-NA})"
  input tap "$RECOVER_YES_X" "$RECOVER_YES_Y" >/dev/null 2>&1
  sleep 1
}

handle_popups() {
  focus="$(current_focus_line)"

  if has_anr; then
    log "ANR detected -> tap WAIT at ${ANR_WAIT_X},${ANR_WAIT_Y} (focus=${focus:-NA})"
    input tap "$ANR_WAIT_X" "$ANR_WAIT_Y" >/dev/null 2>&1
    sleep 2
  fi

  # Recover dialog: best-effort by coords, NOT gated by focus (it can be system dialog)
  maybe_tap_yes_recover
}

wait_unpowered_60s_resetting() {
  secs=0
  while [ "$secs" -lt 60 ]; do
    handle_popups
    if is_powered; then
      return 1
    fi
    sleep 1
    secs=$((secs + 1))
  done
  return 0
}

watch_popups_until_resumed() {
  # actively click popups until TcMainActivity is resumed or timeout
  timeout_s="${1:-600}"
  deadline=$(( $(date +%s) + timeout_s ))

  while [ "$(date +%s)" -lt "$deadline" ]; do
    handle_popups
    if is_pocket_resumed; then
      return 0
    fi
    sleep 1
  done
  return 1
}

log "service.sh start"

until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done
log "boot_completed=1"

sleep 10
log "starting pocket (launcher)"
monkey -p com.tems.pocketlauncher -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1

# Wait for Pocket process (up to 10 minutes) + retry launcher occasionally
log "waiting for process: $PKG"
deadline=$(( $(date +%s) + 600 ))
attempt=1
while [ "$(date +%s)" -lt "$deadline" ]; do
  handle_popups

  if pidof "$PKG" >/dev/null 2>&1; then
    log "process up (pid=$(pidof $PKG))"
    break
  fi

  if [ $((attempt % 20)) -eq 0 ]; then
    log "retry launcher (attempt=$attempt)"
    monkey -p com.tems.pocketlauncher -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  fi

  attempt=$((attempt + 1))
  sleep 2
done

if ! pidof "$PKG" >/dev/null 2>&1; then
  log "timeout waiting process"
  exit 0
fi

# Wait for Pocket activity resumed (up to 10 minutes) WITH popup clicks
log "waiting for resumed activity: $ACT (with popup clicks)"
if ! watch_popups_until_resumed 600; then
  log "timeout waiting focus(resumed)"
  exit 0
fi
log "focus OK (resumed)"

# Wait until the main window is drawn and not just a "starting window"
log "waiting for UI drawn (not starting window)"
deadline=$(( $(date +%s) + 900 ))

is_drawn() {
  dumpsys window windows \
    | grep -A 120 "Window{.* $PKG/$ACT" \
    | grep -q "mDrawState=HAS_DRAWN"
}

has_starting_window() {
  dumpsys window windows | grep -qE "Starting window.*$PKG"
}

stable=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  handle_popups

  if is_drawn && ! has_starting_window; then
    stable=$((stable + 1))
    log "drawn-check ok (stable=$stable)"
  else
    stable=0
    sw=0
    has_starting_window && sw=1
    log "drawn-check not-yet (starting=$sw)"
  fi

  if [ "$stable" -ge 5 ]; then
    log "UI drawn"
    break
  fi

  sleep 2
done

if [ "$stable" -lt 5 ]; then
  log "timeout waiting UI drawn"
  exit 0
fi

sleep 3

# If device is NOT powered, wait for 60s continuously unpowered (resets if power returns), then taps
if ! is_powered; then
  log "device unpowered -> waiting 60s continuously (resets if power returns)"
  while true; do
    if wait_unpowered_60s_resetting; then
      log "device stayed unpowered for 60s -> tap (600,150) and (900,1240)"
      input tap 600 150 >/dev/null 2>&1
      sleep 1
      input tap 900 1240 >/dev/null 2>&1
      sleep 1
      break
    fi
    log "power returned before 60s -> reset timer and wait for unpowered again"
    while is_powered; do
      handle_popups
      sleep 2
    done
  done
else
  log "device is powered -> skip no-power taps"
fi

log "running main taps"
MODDIR="${0%/*}"
/system/bin/sh "$MODDIR/tems_pocket_start.sh"

# Power off: wait up to 15 minutes to observe 60s continuously unpowered (resets if power returns)
log "poweroff: waiting up to 15min for 60s continuously unpowered"
poweroff_deadline=$(( $(date +%s) + 900 ))

while [ "$(date +%s)" -lt "$poweroff_deadline" ]; do
  handle_popups

  if is_powered; then
    sleep 5
    continue
  fi

  if wait_unpowered_60s_resetting; then
    log "poweroff: unpowered 60s confirmed -> shutting down"
    break
  fi

  sleep 2
done

if [ "$(date +%s)" -ge "$poweroff_deadline" ]; then
  log "poweroff: timeout waiting unpowered 60s -> skip shutdown"
  exit 0
fi

log "poweroff: whoami=$(id)"

try() {
  cmd="$*"
  log "poweroff: run: $cmd"
  sh -c "$cmd" >/dev/null 2>&1
  rc=$?
  log "poweroff: rc=$rc for: $cmd"
  return $rc
}

try_su() {
  if command -v su >/dev/null 2>&1; then
    cmd="$*"
    log "poweroff: run as su: $cmd"
    su -c "$cmd" >/dev/null 2>&1
    rc=$?
    log "poweroff: su rc=$rc for: $cmd"
    return $rc
  fi
  log "poweroff: su not found"
  return 127
}

sleep 2

try_su "/system/bin/reboot -p" && exit 0
try_su "/system/bin/reboot poweroff" && exit 0
try_su "svc power shutdown" && exit 0

try "/system/bin/reboot -p" && exit 0
try "/system/bin/reboot poweroff" && exit 0
try "/system/bin/reboot shutdown" && exit 0
try "svc power shutdown" && exit 0

try_su "am start -a android.intent.action.ACTION_REQUEST_SHUTDOWN --ez KEY_CONFIRM false" && exit 0
try "am start -a android.intent.action.ACTION_REQUEST_SHUTDOWN --ez KEY_CONFIRM false" && exit 0

log "poweroff: all methods failed"
exit 0
