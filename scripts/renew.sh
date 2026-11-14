#!/bin/zsh
# Renews DingDing on the iPhone before the free 7-day signature expires.
# Run by launchd every 3 h (installed with scripts/install-renew.sh).
# Usage: renew.sh [--force]
set -u

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
PROJECT="${0:A:h:h}"
# DEVICE (UDID of the iPhone) comes from scripts/renew.env.
[[ -f "$PROJECT/scripts/renew.env" ]] && source "$PROJECT/scripts/renew.env"
if [[ -z "${DEVICE:-}" ]]; then
  print "Crée scripts/renew.env (voir scripts/renew.env.example)." >&2
  exit 1
fi
STATE_DIR="$HOME/Library/Application Support/DingDingRenew"
STATE="$STATE_DIR/expiry"          # ISO date of the signature installed on the iPhone
LAST_WARN="$STATE_DIR/last_warning"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
RENEW_BEFORE_DAYS=4
mkdir -p "$STATE_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*"; }
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1; }
to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null; }

now=$(date +%s)
remaining_days=-1
if [[ -s "$STATE" ]]; then
  exp_epoch=$(to_epoch "$(cat "$STATE")")
  [[ -n "$exp_epoch" ]] && remaining_days=$(( (exp_epoch - now) / 86400 ))
fi

if [[ "${1:-}" != "--force" && $remaining_days -ge $RENEW_BEFORE_DAYS ]]; then
  exit 0   # nothing to do yet
fi

log "Renouvellement (il reste ${remaining_days} j)…"

# Is the iPhone reachable (USB or same Wi-Fi)?
if ! xcrun devicectl device info details --device "$DEVICE" --timeout 45 >/dev/null 2>&1; then
  log "iPhone injoignable, nouvel essai dans 3 h."
  if [[ $remaining_days -le 1 ]]; then
    last=$(cat "$LAST_WARN" 2>/dev/null || echo 0)
    if (( now - last > 6 * 3600 )); then
      notify "DingDing expire bientôt" "Connecte l'iPhone au même Wi-Fi que le Mac (ou en USB) pour la renouveler."
      print $now > "$LAST_WARN"
    fi
  fi
  exit 0
fi

# Force fresh 7-day provisioning profiles.
for f in "$PROFILES"/*.mobileprovision(N); do
  name=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null)
  [[ "$name" == *dingding* ]] && rm -f "$f"
done

cd "$PROJECT" || exit 1
if ! xcodebuild -scheme DingDing -configuration Release \
      -destination "id=$DEVICE" -derivedDataPath build.noindex \
      -allowProvisioningUpdates build > "$STATE_DIR/last_build.log" 2>&1; then
  log "Échec de la compilation (voir $STATE_DIR/last_build.log)."
  notify "DingDing" "Le renouvellement a échoué : compilation impossible."
  exit 1
fi

APP="$PROJECT/build.noindex/Build/Products/Release-iphoneos/DingDing.app"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" > "$STATE_DIR/last_install.log" 2>&1; then
  log "Échec de l'installation (voir $STATE_DIR/last_install.log)."
  exit 1
fi

new_exp=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null)
print -r -- "$new_exp" > "$STATE"
rm -f "$LAST_WARN"
log "DingDing renouvelée jusqu'au $new_exp."
notify "DingDing renouvelée ✅" "Valable jusqu'au $(date -j -f '%s' "$(to_epoch "$new_exp")" '+%d/%m à %H:%M')."
