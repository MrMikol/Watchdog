#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="/var/lib/net-watchdog"
FAILS_FILE="${STATE_DIR}/fails"
LAST_REBOOT_FILE="${STATE_DIR}/last_reboot_epoch"

CHECK_EVERY_SECONDS=300

REMEDIATE_AFTER_FAILS=2
REBOOT_AFTER_FAILS=4

# Prevent reboot loops if ISP is down for hours
REBOOT_COOLDOWN_SECONDS=3600

CHECK_IP_TARGET="1.1.1.1"
CHECK_URL="https://connectivitycheck.gstatic.com/generate_204"

log() { echo "$(date -Is) $*"; }

host() {
  # Run command on host by entering PID 1 namespaces
  nsenter -t 1 -m -u -i -n -p -- "$@"
}

check_connectivity() {
  ping -c 1 -W 2 "$CHECK_IP_TARGET" >/dev/null 2>&1 || return 1
  curl -fsS --max-time 8 "$CHECK_URL" >/dev/null 2>&1 || return 1
  return 0
}

restart_if_present() {
  local svc="$1"
  if host systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    log "ACTION: restarting ${svc}.service"
    host systemctl restart "${svc}.service" || log "WARN: failed to restart ${svc}.service"
  else
    log "SKIP: ${svc}.service not installed"
  fi
}

snapshot() {
  log "SNAPSHOT: ip route"
  host ip route || true
  log "SNAPSHOT: DNS status"
  host sh -c 'command -v resolvectl >/dev/null && resolvectl status || cat /etc/resolv.conf' || true
}

can_reboot_now() {
  local now last
  now="$(date +%s)"
  last="0"
  [ -f "$LAST_REBOOT_FILE" ] && last="$(cat "$LAST_REBOOT_FILE" || echo 0)"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= REBOOT_COOLDOWN_SECONDS )); then
    return 0
  fi
  log "INFO: reboot suppressed by cooldown (last reboot $((now-last))s ago, cooldown=${REBOOT_COOLDOWN_SECONDS}s)"
  return 1
}

mkdir -p "$STATE_DIR"
touch "$FAILS_FILE"
log "net-watchdog started (interval=${CHECK_EVERY_SECONDS}s)"

while true; do
  fails="$(cat "$FAILS_FILE" 2>/dev/null || echo 0)"
  [[ "$fails" =~ ^[0-9]+$ ]] || fails=0

  if check_connectivity; then
    if [ "$fails" -ne 0 ]; then log "RECOVERED: connectivity OK again (was failing $fails runs)"; fi
    echo 0 > "$FAILS_FILE"
    sleep "$CHECK_EVERY_SECONDS"
    continue
  fi

  fails=$((fails + 1))
  echo "$fails" > "$FAILS_FILE"
  log "FAIL: connectivity check failed (consecutive fails=$fails)"

  if [ "$fails" -lt "$REMEDIATE_AFTER_FAILS" ]; then
    log "INFO: waiting for next run before remediation"
    sleep "$CHECK_EVERY_SECONDS"
    continue
  fi

  log "INFO: remediation triggered"
  snapshot

  # As requested: do NOT restart ssh
  restart_if_present "tailscaled"
  restart_if_present "systemd-resolved"
  restart_if_present "NetworkManager"
  restart_if_present "systemd-networkd"

  if check_connectivity; then
    log "FIXED: connectivity restored after remediation"
    echo 0 > "$FAILS_FILE"
    sleep "$CHECK_EVERY_SECONDS"
    continue
  fi

  log "STILL DOWN: connectivity still failing after remediation (fails=$fails)"

  if [ "$fails" -ge "$REBOOT_AFTER_FAILS" ] && can_reboot_now; then
    log "REBOOT: threshold reached. Rebooting host."
    date +%s > "$LAST_REBOOT_FILE"
    host /sbin/reboot
  fi

  sleep "$CHECK_EVERY_SECONDS"
done
