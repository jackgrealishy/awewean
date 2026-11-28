#!/usr/bin/env bash
set -Eeuo pipefail
# Simple standalone Seine miner + optional Cloudflare/Render WSS relay.
# Keep this script beside ./seine and ./cf-relay-bridge.py.
# Uses systemd when available; otherwise uses a private Supervisor instance.
ADDRESS="${ADDRESS:-7eseCPTmrS9bmYs4oonUq3WjMxTW8nsY3ueyYCBCT6BTWiWAxHGKmMEaGuUexXXxzYUWt95NmnxZMvQC5GLqcDEzQJEWm}"
MODE="${MODE:-relay}"                         # relay | direct
POOL_URL="${POOL_URL:-stratum+tcp://bntpool.com:3333}"
RELAY_URL="${RELAY_URL:-wss://relay.saamaaeel.my.id/bntpool}"
RELAY_TARGET="${RELAY_TARGET:-bntpool.com:3333}"
RELAY_LOCAL_PORT="${RELAY_LOCAL_PORT:-33333}"
RELAY_CHECK="${RELAY_CHECK:-1}"               # 1 = test Worker -> pool first
RELAY_CONNECT_TIMEOUT="${RELAY_CONNECT_TIMEOUT:-15}"
RELAY_CHECK_TIMEOUT="${RELAY_CHECK_TIMEOUT:-90}"
# Current 4-vCPU / 32-GiB trial defaults.
CPU_THREADS="${CPU_THREADS:-}"  # Empty = let Seine auto-size and tune CPU threads.
CPU_MEMORY_RESERVE_PERCENT="${CPU_MEMORY_RESERVE_PERCENT:-0}"
# Use auto because this runtime did not expose HugeTLB information.
# Seine may use the best page mode available on the host.
CPU_PAGE_MODE="${CPU_PAGE_MODE:-auto}"
POOL_WORKER="${POOL_WORKER:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MINER="${SCRIPT_DIR}/seine"
BRIDGE="${SCRIPT_DIR}/cf-relay-bridge.py"
BRIDGE_LOG="${SCRIPT_DIR}/cf-relay-bridge.log"
BRIDGE_PID=""
SERVICE_CHILD=0
FOREGROUND=0
SERVICE_NAME="seine-miner.service"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"  # override only for isolated testing
SERVICE_FILE="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}"
SERVICE_ENV="${SERVICE_ENV:-/etc/default/seine-miner}"
# Supervisor runs in a user-writable state directory; this works without systemd
# and does not depend on the distro's system Supervisor service.
SUPERVISOR_STATE_DIR="${SUPERVISOR_STATE_DIR:-${HOME:-/tmp}/.seine-supervisor}"
SUPERVISOR_CONFIG="${SUPERVISOR_CONFIG:-${SUPERVISOR_STATE_DIR}/supervisord.conf}"
SUPERVISOR_SOCKET="${SUPERVISOR_SOCKET:-${SUPERVISOR_STATE_DIR}/supervisor.sock}"
SUPERVISOR_PIDFILE="${SUPERVISOR_PIDFILE:-${SUPERVISOR_STATE_DIR}/supervisord.pid}"
SUPERVISOR_VENV="${SUPERVISOR_VENV:-${SUPERVISOR_STATE_DIR}/venv}"
SUPERVISOR_RUNNER="${SUPERVISOR_RUNNER:-${SUPERVISOR_STATE_DIR}/seine-supervisor-runner.sh}"
SUPERVISOR_BOOT_HELPER="${SUPERVISOR_BOOT_HELPER:-${SUPERVISOR_STATE_DIR}/start-supervisor.sh}"
SUPERVISOR_FOREGROUND_HELPER="${SUPERVISOR_FOREGROUND_HELPER:-${SUPERVISOR_STATE_DIR}/run-supervisor-foreground.sh}"
SUPERVISOR_CONFIG_HASH="${SUPERVISOR_CONFIG_HASH:-${SUPERVISOR_STATE_DIR}/runtime-config.sha256}"
SUPERVISOR_MAX_STARTS="${SUPERVISOR_MAX_STARTS:-5}"
SUPERVISOR_START_WINDOW="${SUPERVISOR_START_WINDOW:-300}"
SUPERVISORD_BIN="${SUPERVISORD_BIN:-}"
SUPERVISORCTL_BIN="${SUPERVISORCTL_BIN:-}"

# Keep the automatically generated worker stable between invocations. A new
# random worker on every launch would look like a configuration change.
if [[ -z "$POOL_WORKER" ]]; then
  if [[ -r "${SUPERVISOR_STATE_DIR}/pool-worker" ]]; then
    IFS= read -r POOL_WORKER < "${SUPERVISOR_STATE_DIR}/pool-worker" || true
  fi
  if [[ -z "$POOL_WORKER" ]]; then
    POOL_WORKER="$(printf 'w%04x%04x' "$RANDOM" "$RANDOM")"
    if mkdir -p "$SUPERVISOR_STATE_DIR" 2>/dev/null; then
      printf '%s\n' "$POOL_WORKER" > "${SUPERVISOR_STATE_DIR}/pool-worker" 2>/dev/null || true
    fi
  fi
fi
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: ./$(basename -- "$0") [options]
Connection:
  --mode relay|direct       Connection mode (default: ${MODE})
  --relay URL               WSS relay URL (default: ${RELAY_URL})
  --target HOST:PORT        Pool behind relay (default: ${RELAY_TARGET})
  --pool URL                Direct pool URL (default: ${POOL_URL})
  --local-port PORT         Local relay listener (default: ${RELAY_LOCAL_PORT})
  --connect-timeout SEC     Relay connection timeout (default: ${RELAY_CONNECT_TIMEOUT})
  --check-timeout SEC       Relay probe timeout (default: ${RELAY_CHECK_TIMEOUT})
  --no-check                Skip relay -> pool probe
  --check                   Enable relay -> pool probe
Mining:
  --address ADDRESS         Payout address
  --threads N               Optional fixed CPU thread count (default: automatic)
  --cpu-memory-reserve-percent N  RAM reserve percent (default: ${CPU_MEMORY_RESERVE_PERCENT})
  --page-mode MODE          auto, regular, large, large-1g (default: ${CPU_PAGE_MODE})
  --pool-worker NAME        Worker label (default: ${POOL_WORKER})
Service:
  Default                     Use systemd if available; otherwise use Supervisor.
  --foreground                Run directly without installing/using a service manager.

Other:
  -h, --help                  Show this help

Systemd controls:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  systemctl stop ${SERVICE_NAME}

Supervisor controls (when systemd is unavailable):
  supervisorctl -c "${SUPERVISOR_CONFIG}" status
  supervisorctl -c "${SUPERVISOR_CONFIG}" tail -f seine-miner
  supervisorctl -c "${SUPERVISOR_CONFIG}" stop seine-miner
USAGE
}
while (($#)); do
  case "$1" in
    --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
    --relay) RELAY_URL="${2:?--relay requires a URL}"; shift 2 ;;
    --target) RELAY_TARGET="${2:?--target requires HOST:PORT}"; shift 2 ;;
    --pool) POOL_URL="${2:?--pool requires a URL}"; shift 2 ;;
    --local-port) RELAY_LOCAL_PORT="${2:?--local-port requires a port}"; shift 2 ;;
    --connect-timeout) RELAY_CONNECT_TIMEOUT="${2:?--connect-timeout requires seconds}"; shift 2 ;;
    --check-timeout) RELAY_CHECK_TIMEOUT="${2:?--check-timeout requires seconds}"; shift 2 ;;
    --address) ADDRESS="${2:?--address requires a value}"; shift 2 ;;
    --threads) CPU_THREADS="${2:?--threads requires a number}"; shift 2 ;;
    --cpu-memory-reserve-percent) CPU_MEMORY_RESERVE_PERCENT="${2:?--cpu-memory-reserve-percent requires a number}"; shift 2 ;;
    --page-mode) CPU_PAGE_MODE="${2:?--page-mode requires a value}"; shift 2 ;;
    --pool-worker) POOL_WORKER="${2:?--pool-worker requires a value}"; shift 2 ;;
    --foreground) FOREGROUND=1; shift ;;
    --service-child) SERVICE_CHILD=1; shift ;;
    --check) RELAY_CHECK=1; shift ;;
    --no-check) RELAY_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done
case "$MODE" in relay|direct) ;; *) die "--mode must be relay or direct" ;; esac
case "$RELAY_CHECK" in 0|1) ;; *) die "RELAY_CHECK must be 0 or 1" ;; esac
if [[ -n "$CPU_THREADS" ]]; then
  [[ "$CPU_THREADS" =~ ^[1-9][0-9]*$ ]] || die "--threads must be a positive integer"
fi
[[ "$CPU_MEMORY_RESERVE_PERCENT" =~ ^[0-9]+$ ]] || die "--cpu-memory-reserve-percent must be an integer from 0 to 99"
(( CPU_MEMORY_RESERVE_PERCENT <= 99 )) || die "--cpu-memory-reserve-percent must be from 0 to 99"
case "$CPU_PAGE_MODE" in auto|regular|large|large-1g) ;; *) die "Invalid page mode: $CPU_PAGE_MODE" ;; esac
[[ "$RELAY_LOCAL_PORT" =~ ^[0-9]+$ ]] && (( RELAY_LOCAL_PORT >= 1024 && RELAY_LOCAL_PORT <= 65535 )) || die "Local port must be between 1024 and 65535"
[[ "$RELAY_CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "RELAY_CONNECT_TIMEOUT must be positive"
[[ "$RELAY_CHECK_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "RELAY_CHECK_TIMEOUT must be positive"
[[ -n "$ADDRESS" ]] || die "Payout address cannot be empty"
if [[ "$MODE" == relay ]]; then
  [[ "$RELAY_URL" == ws://* || "$RELAY_URL" == wss://* ]] || die "Relay URL must start with ws:// or wss://"
  [[ -n "$RELAY_TARGET" ]] || die "Relay target cannot be empty"
fi
[[ -f "$MINER" ]] || die "Seine binary not found: $MINER (place ./seine beside this script)"
if [[ ! -x "$MINER" ]]; then
  chmod +x "$MINER" || die "Cannot make Seine executable: $MINER"
fi
if [[ "$MODE" == relay ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 is required for relay mode"
  [[ -f "$BRIDGE" ]] || die "Relay bridge not found: $BRIDGE (place cf-relay-bridge.py beside this script)"
fi
# ------------------------- systemd installation --------------------------

# The service loads its complete runtime configuration from EnvironmentFile,
# then re-enters this same script in foreground/service-child mode.
systemd_quote_arg() {
  local value="$1" escaped
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || die 'Newline characters are not allowed in systemd arguments.'
  escaped="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')"
  printf '"%s"' "$escaped"
}
# Path-valued systemd settings use C-style escapes rather than shell quotes.
systemd_path_value() {
  local value="$1"
  value=${value//\\/\\x5c}
  value=${value// /\\x20}
  value=${value//$'\t'/\\x09}
  value=${value//%/%%}
  printf '%s' "$value"
}
systemd_env_quote() {
  local value="$1" escaped
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || die 'Configuration values must not contain newline characters.'
  escaped="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '"%s"' "$escaped"
}

install_systemd_service() {
  local unit_tmp env_tmp script_path
  command -v systemctl >/dev/null 2>&1 || die 'systemctl is unavailable; use --foreground to run without a service.'
  [[ "$EUID" -eq 0 ]] || die 'Root is required to install a system service; use --foreground instead.'
  systemctl show-environment >/dev/null 2>&1 || die 'No system systemd manager is available; use --foreground instead.'
  script_path="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
  install -d -o root -g root "${SYSTEMD_UNIT_DIR}" "$(dirname -- "$SERVICE_ENV")"
  unit_tmp="$(mktemp)"
  env_tmp="$(mktemp)"
  {
    printf 'ADDRESS=%s\n' "$(systemd_env_quote "$ADDRESS")"
    printf 'MODE=%s\n' "$(systemd_env_quote "$MODE")"
    printf 'POOL_URL=%s\n' "$(systemd_env_quote "$POOL_URL")"
    printf 'RELAY_URL=%s\n' "$(systemd_env_quote "$RELAY_URL")"
    printf 'RELAY_TARGET=%s\n' "$(systemd_env_quote "$RELAY_TARGET")"
    printf 'RELAY_LOCAL_PORT=%s\n' "$(systemd_env_quote "$RELAY_LOCAL_PORT")"
    printf 'RELAY_CHECK=%s\n' "$(systemd_env_quote "$RELAY_CHECK")"
    printf 'RELAY_CONNECT_TIMEOUT=%s\n' "$(systemd_env_quote "$RELAY_CONNECT_TIMEOUT")"
    printf 'RELAY_CHECK_TIMEOUT=%s\n' "$(systemd_env_quote "$RELAY_CHECK_TIMEOUT")"
    printf 'CPU_THREADS=%s\n' "$(systemd_env_quote "$CPU_THREADS")"
    printf 'CPU_MEMORY_RESERVE_PERCENT=%s\n' "$(systemd_env_quote "$CPU_MEMORY_RESERVE_PERCENT")"
    printf 'CPU_PAGE_MODE=%s\n' "$(systemd_env_quote "$CPU_PAGE_MODE")"
    printf 'POOL_WORKER=%s\n' "$(systemd_env_quote "$POOL_WORKER")"
  } > "$env_tmp"
  cat > "$unit_tmp" <<EOF_UNIT
[Unit]
Description=Seine CPU miner with optional WSS relay
Wants=network-online.target
After=network-online.target
# Stop repeated crash loops: no more than 5 starts in a 5-minute window.
StartLimitIntervalSec=300
StartLimitBurst=5
[Service]
Type=simple
User=root
WorkingDirectory=$(systemd_path_value "$SCRIPT_DIR")
EnvironmentFile=${SERVICE_ENV}
Environment=LANG=C
Environment=LC_ALL=C
ExecStartPre=/bin/sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true'
ExecStart=/bin/bash $(systemd_quote_arg "$script_path") --service-child
Restart=always
RestartSec=10s
OOMPolicy=continue
KillSignal=SIGINT
KillMode=control-group
TimeoutStopSec=30s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
EOF_UNIT

  if ! install -o root -g root -m 0600 "$env_tmp" "$SERVICE_ENV"; then
    rm -f "$unit_tmp" "$env_tmp"
    die "Could not install service environment file: $SERVICE_ENV"
  fi
  if ! install -o root -g root -m 0644 "$unit_tmp" "$SERVICE_FILE"; then
    rm -f "$unit_tmp" "$env_tmp"
    die "Could not install systemd unit: $SERVICE_FILE"
  fi
  rm -f "$unit_tmp" "$env_tmp"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "Restarting existing ${SERVICE_NAME} with the updated configuration."
    if ! systemctl restart "$SERVICE_NAME"; then
      journalctl -u "$SERVICE_NAME" -n 40 --no-pager >&2 || true
      die "Could not restart ${SERVICE_NAME}."
    fi
  else
    log "Starting and enabling ${SERVICE_NAME} at boot."
    if ! systemctl start "$SERVICE_NAME"; then
      journalctl -u "$SERVICE_NAME" -n 40 --no-pager >&2 || true
      die "Could not start ${SERVICE_NAME}."
    fi
  fi
  log "${SERVICE_NAME} is enabled. It will restart after unexpected exits and start again after reboot."
  log "Check logs with: journalctl -u ${SERVICE_NAME} -f"
}

# ------------------------- Supervisor fallback ---------------------------

# Supervisor config values use ConfigParser interpolation: percent signs must
# be doubled. Double quotes and backslashes are escaped for environment values.
supervisor_env_quote() {
  local value="$1" escaped
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  escaped="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')"
  printf '"%s"' "$escaped"
}
supervisor_command_quote() {
  local value="$1" escaped
  escaped="$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/%/%%/g')"
  printf '"%s"' "$escaped"
}
supervisor_conf_path() {
  printf '%s' "$1" | sed 's/%/%%/g'
}
shell_single_quote() {
  local value="$1"
  value=${value//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

ensure_supervisor() {
  local venv_python
  SUPERVISORD_BIN="${SUPERVISORD_BIN:-$(command -v supervisord 2>/dev/null || true)}"
  SUPERVISORCTL_BIN="${SUPERVISORCTL_BIN:-$(command -v supervisorctl 2>/dev/null || true)}"
  if [[ -x "$SUPERVISORD_BIN" && -x "$SUPERVISORCTL_BIN" ]]; then
    return 0
  fi

  # On Debian/Ubuntu, prefer the OS package when running as root.
  if [[ "$EUID" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    log 'Supervisor is missing; trying to install the supervisor package with apt-get.'
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor; then
      log 'Package cache may be stale; refreshing apt indexes and retrying.'
      if ! DEBIAN_FRONTEND=noninteractive apt-get update; then
        log 'apt-get update failed; will try a Python virtual environment instead.'
      elif ! DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor; then
        log 'apt-get could not install Supervisor; will try a Python virtual environment instead.'
      fi
    fi
  fi

  SUPERVISORD_BIN="$(command -v supervisord 2>/dev/null || true)"
  SUPERVISORCTL_BIN="$(command -v supervisorctl 2>/dev/null || true)"
  if [[ -x "$SUPERVISORD_BIN" && -x "$SUPERVISORCTL_BIN" ]]; then
    return 0
  fi

  # Fallback for non-root/minimal containers: install Supervisor into its own
  # venv so the system Python environment is not modified.
  command -v python3 >/dev/null 2>&1 || {
    log 'Python 3 is unavailable; cannot install Supervisor automatically.'
    return 1
  }
  mkdir -p "$SUPERVISOR_STATE_DIR" || return 1
  if [[ ! -x "${SUPERVISOR_VENV}/bin/supervisord" || ! -x "${SUPERVISOR_VENV}/bin/supervisorctl" ]]; then
    log "Installing Supervisor into ${SUPERVISOR_VENV}."
    if ! python3 -m venv "$SUPERVISOR_VENV"; then
      log 'Could not create a Python virtual environment (the python3-venv package may be missing).'
      return 1
    fi
    venv_python="${SUPERVISOR_VENV}/bin/python"
    if ! "$venv_python" -m pip install --disable-pip-version-check --upgrade supervisor; then
      log 'Could not install Supervisor with pip.'
      return 1
    fi
  fi
  SUPERVISORD_BIN="${SUPERVISOR_VENV}/bin/supervisord"
  SUPERVISORCTL_BIN="${SUPERVISOR_VENV}/bin/supervisorctl"
  [[ -x "$SUPERVISORD_BIN" && -x "$SUPERVISORCTL_BIN" ]]
}

write_supervisor_runner() {
  local tmp
  tmp="$(mktemp "${SUPERVISOR_RUNNER}.XXXXXX")" || return 1
  {
    printf '#!/usr/bin/env bash\nset -u\nSCRIPT_PATH=%q\n' "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
    printf 'MAX_STARTS=%q\nWINDOW_SECONDS=%q\n' "$SUPERVISOR_MAX_STARTS" "$SUPERVISOR_START_WINDOW"
    cat <<'RUNNER_BODY'
start_times=()
child_pid=""
sleep_pid=""
stopping=0

stop_runner() {
  stopping=1
  [[ -n "$child_pid" ]] && kill -TERM "$child_pid" 2>/dev/null || true
  [[ -n "$sleep_pid" ]] && kill -TERM "$sleep_pid" 2>/dev/null || true
}
trap stop_runner INT TERM

prune_start_times() {
  local now ts
  local -a recent=()
  now="$(date +%s)"
  for ts in "${start_times[@]}"; do
    if (( now - ts < WINDOW_SECONDS )); then
      recent+=("$ts")
    fi
  done
  start_times=("${recent[@]}")
}

while :; do
  (( stopping )) && exit 0
  prune_start_times
  if (( ${#start_times[@]} >= MAX_STARTS )); then
    printf '[%s] Restart limit reached (%s starts in %s seconds); leaving Seine stopped.\n' \
      "$(date '+%F %T')" "$MAX_STARTS" "$WINDOW_SECONDS" >&2
    exit 0
  fi

  started_at="$(date +%s)"
  start_times+=("$started_at")
  printf '[%s] Launching Seine service child (attempt %s/%s in rolling window).\n' \
    "$(date '+%F %T')" "${#start_times[@]}" "$MAX_STARTS" >&2
  /bin/bash "$SCRIPT_PATH" --service-child &
  child_pid=$!
  wait "$child_pid"
  child_status=$?
  child_pid=""
  (( stopping )) && exit 0

  printf '[%s] Seine service child exited with status %s.\n' \
    "$(date '+%F %T')" "$child_status" >&2
  prune_start_times
  if (( ${#start_times[@]} >= MAX_STARTS )); then
    printf '[%s] Restart limit reached; stopping retries until manually restarted.\n' \
      "$(date '+%F %T')" >&2
    exit 0
  fi

  delay=$((5 * (2 ** (${#start_times[@]} - 1))))
  (( delay > 60 )) && delay=60
  printf '[%s] Retrying in %s seconds.\n' "$(date '+%F %T')" "$delay" >&2
  sleep "$delay" &
  sleep_pid=$!
  wait "$sleep_pid" || true
  sleep_pid=""
  (( stopping )) && exit 0
done
RUNNER_BODY
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" && mv -f "$tmp" "$SUPERVISOR_RUNNER"
}

write_supervisor_foreground_helper() {
  local tmp
  tmp="$(mktemp "${SUPERVISOR_FOREGROUND_HELPER}.XXXXXX")" || return 1
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'SUPERVISORD_BIN=%q\nSUPERVISOR_CONFIG=%q\n' \
      "$SUPERVISORD_BIN" "$SUPERVISOR_CONFIG"
    cat <<'FOREGROUND_BODY'
# Use this as the container command/entrypoint when this container has no init.
# It keeps supervisord in the foreground so it remains the container's main process.
exec "$SUPERVISORD_BIN" -n -c "$SUPERVISOR_CONFIG"
FOREGROUND_BODY
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" && mv -f "$tmp" "$SUPERVISOR_FOREGROUND_HELPER"
}

write_supervisor_boot_helper() {
  local tmp
  tmp="$(mktemp "${SUPERVISOR_BOOT_HELPER}.XXXXXX")" || return 1
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
    printf 'SUPERVISORD_BIN=%q\nSUPERVISORCTL_BIN=%q\nSUPERVISOR_CONFIG=%q\n' \
      "$SUPERVISORD_BIN" "$SUPERVISORCTL_BIN" "$SUPERVISOR_CONFIG"
    printf 'SUPERVISOR_PIDFILE=%q\nSUPERVISOR_SOCKET=%q\nSTATE_DIR=%q\n' \
      "$SUPERVISOR_PIDFILE" "$SUPERVISOR_SOCKET" "$SUPERVISOR_STATE_DIR"
    cat <<'BOOT_BODY'
mkdir -p "$STATE_DIR"
if "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid >/dev/null 2>&1; then
  exit 0
fi
if [[ -f "$SUPERVISOR_PIDFILE" ]]; then
  old_pid="$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    for _ in {1..50}; do
      "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid >/dev/null 2>&1 && exit 0
      sleep 0.2
    done
    printf '[%s] Existing supervisord PID %s is alive but its socket is unavailable.\n' \
      "$(date '+%F %T')" "$old_pid" >&2
    exit 1
  fi
  rm -f "$SUPERVISOR_PIDFILE" "$SUPERVISOR_SOCKET"
else
  rm -f "$SUPERVISOR_SOCKET"
fi
"$SUPERVISORD_BIN" -c "$SUPERVISOR_CONFIG"
for _ in {1..50}; do
  "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid >/dev/null 2>&1 && exit 0
  sleep 0.2
done
printf '[%s] supervisord did not become ready from boot helper.\n' "$(date '+%F %T')" >&2
exit 1
BOOT_BODY
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 700 "$tmp" && mv -f "$tmp" "$SUPERVISOR_BOOT_HELPER"
}

cron_is_running() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
    return $?
  fi
  ps -eo comm= 2>/dev/null | grep -Eq '^(cron|crond)$'
}

install_cron_package_if_needed() {
  command -v crontab >/dev/null 2>&1 && return 0
  [[ "$EUID" -eq 0 ]] || return 1
  if command -v apt-get >/dev/null 2>&1; then
    log 'crontab is missing; attempting to install cron for the Supervisor boot hook.'
    DEBIAN_FRONTEND=noninteractive apt-get install -y cron || true
  elif command -v apk >/dev/null 2>&1; then
    log 'crontab is missing; attempting to install dcron for the Supervisor boot hook.'
    apk add --no-cache dcron || true
  elif command -v dnf >/dev/null 2>&1; then
    log 'crontab is missing; attempting to install cronie for the Supervisor boot hook.'
    dnf install -y cronie || true
  elif command -v yum >/dev/null 2>&1; then
    log 'crontab is missing; attempting to install cronie for the Supervisor boot hook.'
    yum install -y cronie || true
  fi
  command -v crontab >/dev/null 2>&1
}

ensure_cron_boot_service() {
  local enabled=0
  if [[ "$EUID" -eq 0 ]]; then
    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
      if rc-update add crond default >/dev/null 2>&1 || rc-update add cron default >/dev/null 2>&1; then
        enabled=1
      fi
      rc-service crond start >/dev/null 2>&1 || rc-service cron start >/dev/null 2>&1 || true
    elif command -v update-rc.d >/dev/null 2>&1; then
      if update-rc.d cron defaults >/dev/null 2>&1; then enabled=1; fi
      service cron start >/dev/null 2>&1 || cron >/dev/null 2>&1 || true
    elif command -v chkconfig >/dev/null 2>&1; then
      if chkconfig crond on >/dev/null 2>&1; then enabled=1; fi
      service crond start >/dev/null 2>&1 || crond >/dev/null 2>&1 || true
    elif command -v service >/dev/null 2>&1; then
      service cron start >/dev/null 2>&1 || service crond start >/dev/null 2>&1 || true
    elif command -v cron >/dev/null 2>&1; then
      cron >/dev/null 2>&1 || true
    elif command -v crond >/dev/null 2>&1; then
      crond -b >/dev/null 2>&1 || true
    fi
  fi

  if cron_is_running; then
    if (( enabled )); then
      log 'Cron is enabled through the host init system and is running.'
    else
      log 'Cron is running now. A container without an init/entrypoint hook may still need to start cron after a full container restart.'
    fi
  else
    log 'WARNING: The @reboot entry is registered, but no cron daemon is running. The host/container must start cron at boot.'
  fi
}

install_supervisor_boot_hook() {
  local existing tmp boot_line
  if ! install_cron_package_if_needed; then
    log 'No crontab command is available; cannot register an @reboot hook automatically.'
    return 1
  fi
  if ! write_supervisor_boot_helper; then
    log 'Could not write the Supervisor boot helper.'
    return 1
  fi
  boot_line="@reboot /bin/bash $(shell_single_quote "$SUPERVISOR_BOOT_HELPER") >> $(shell_single_quote "${SUPERVISOR_STATE_DIR}/boot.log") 2>&1 # seine-supervisor-boot"
  existing="$(crontab -l 2>/dev/null || true)"
  tmp="$(mktemp)" || return 1
  {
    if [[ -n "$existing" ]]; then
      printf '%s\n' "$existing" | sed '/# seine-supervisor-boot$/d'
    fi
    printf '%s\n' "$boot_line"
  } > "$tmp"
  if ! crontab "$tmp"; then
    rm -f "$tmp"
    log 'Could not install the crontab @reboot entry.'
    return 1
  fi
  rm -f "$tmp"
  ensure_cron_boot_service
  log "Supervisor boot helper: ${SUPERVISOR_BOOT_HELPER}"
  log 'Registered an @reboot crontab entry. It runs after reboot only when the host/container starts its cron daemon.'
}

supervisor_runtime_fingerprint() {
  local launcher_path launcher_hash
  launcher_path="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
  launcher_hash="$(sha256sum "$launcher_path" | awk '{print $1}')" || return 1
  printf '%s\0' \
    "$ADDRESS" "$MODE" "$POOL_URL" "$RELAY_URL" "$RELAY_TARGET" \
    "$RELAY_LOCAL_PORT" "$RELAY_CHECK" "$RELAY_CONNECT_TIMEOUT" \
    "$RELAY_CHECK_TIMEOUT" "$CPU_THREADS" "$CPU_MEMORY_RESERVE_PERCENT" \
    "$CPU_PAGE_MODE" "$POOL_WORKER" "$SUPERVISOR_MAX_STARTS" \
    "$SUPERVISOR_START_WINDOW" "$launcher_hash" | sha256sum | awk '{print $1}'
}

install_supervisor_service() {
  local script_path ready status_output runtime_hash saved_hash
  local program_pid_before program_pid_after
  if ! ensure_supervisor; then
    log 'Supervisor is unavailable and automatic installation did not succeed.'
    return 1
  fi
  if ! mkdir -p "$SUPERVISOR_STATE_DIR"; then
    log "Cannot create Supervisor state directory: ${SUPERVISOR_STATE_DIR}"
    return 1
  fi
  chmod 700 "$SUPERVISOR_STATE_DIR" 2>/dev/null || true
  script_path="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
  [[ "$SUPERVISOR_MAX_STARTS" =~ ^[1-9][0-9]*$ ]] || { log 'SUPERVISOR_MAX_STARTS must be a positive integer.'; return 1; }
  [[ "$SUPERVISOR_START_WINDOW" =~ ^[1-9][0-9]*$ ]] || { log 'SUPERVISOR_START_WINDOW must be a positive integer.'; return 1; }

  if ! write_supervisor_runner; then
    log 'Could not write the Supervisor rate-limited runner.'
    return 1
  fi

  cat > "$SUPERVISOR_CONFIG" <<EOF_SUPERVISOR
[unix_http_server]
file=$(supervisor_conf_path "$SUPERVISOR_SOCKET")
chmod=0700

[supervisord]
logfile=$(supervisor_conf_path "${SUPERVISOR_STATE_DIR}/supervisord.log")
logfile_maxbytes=10MB
logfile_backups=3
pidfile=$(supervisor_conf_path "$SUPERVISOR_PIDFILE")
childlogdir=$(supervisor_conf_path "$SUPERVISOR_STATE_DIR")
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory=supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://$(supervisor_conf_path "$SUPERVISOR_SOCKET")

[program:seine-miner]
command=/bin/bash $(supervisor_command_quote "$SUPERVISOR_RUNNER")
autostart=true
autorestart=unexpected
exitcodes=0
startsecs=5
startretries=5
stopsignal=INT
stopwaitsecs=45
stopasgroup=true
killasgroup=true
stdout_logfile=$(supervisor_conf_path "${SUPERVISOR_STATE_DIR}/seine.log")
stderr_logfile=$(supervisor_conf_path "${SUPERVISOR_STATE_DIR}/seine-error.log")
redirect_stderr=false
environment=ADDRESS=$(supervisor_env_quote "$ADDRESS"),MODE=$(supervisor_env_quote "$MODE"),POOL_URL=$(supervisor_env_quote "$POOL_URL"),RELAY_URL=$(supervisor_env_quote "$RELAY_URL"),RELAY_TARGET=$(supervisor_env_quote "$RELAY_TARGET"),RELAY_LOCAL_PORT=$(supervisor_env_quote "$RELAY_LOCAL_PORT"),RELAY_CHECK=$(supervisor_env_quote "$RELAY_CHECK"),RELAY_CONNECT_TIMEOUT=$(supervisor_env_quote "$RELAY_CONNECT_TIMEOUT"),RELAY_CHECK_TIMEOUT=$(supervisor_env_quote "$RELAY_CHECK_TIMEOUT"),CPU_THREADS=$(supervisor_env_quote "$CPU_THREADS"),CPU_MEMORY_RESERVE_PERCENT=$(supervisor_env_quote "$CPU_MEMORY_RESERVE_PERCENT"),CPU_PAGE_MODE=$(supervisor_env_quote "$CPU_PAGE_MODE"),POOL_WORKER=$(supervisor_env_quote "$POOL_WORKER")
EOF_SUPERVISOR

  # Check the daemon connection, not the managed program state. A FATAL/STOPPED
  # child must not be mistaken for a dead supervisord process.
  if ! "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid >/dev/null 2>&1; then
    if [[ -f "$SUPERVISOR_PIDFILE" ]]; then
      local old_pid
      old_pid="$(cat "$SUPERVISOR_PIDFILE" 2>/dev/null || true)"
      if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
        log 'Supervisor appears to be starting; waiting for its control socket.'
      else
        rm -f "$SUPERVISOR_PIDFILE" "$SUPERVISOR_SOCKET"
      fi
    else
      rm -f "$SUPERVISOR_SOCKET"
    fi
    if ! "$SUPERVISORD_BIN" -c "$SUPERVISOR_CONFIG"; then
      log 'Could not launch supervisord.'
      return 1
    fi
  fi

  ready=0
  for ((attempt=0; attempt<50; attempt++)); do
    if "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.2
  done
  if (( ready == 0 )); then
    log 'Supervisor control socket did not become ready. Recent Supervisor log:'
    tail -n 40 "${SUPERVISOR_STATE_DIR}/supervisord.log" >&2 2>/dev/null || true
    return 1
  fi

  # Capture the current process ID so we can tell whether `update` already
  # restarted the process after a changed Supervisor program definition.
  program_pid_before="$("$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid seine-miner 2>/dev/null || true)"
  if ! "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" reread; then
    log 'Supervisor could not reread its configuration.'
    return 1
  fi
  if ! "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" update; then
    log 'Supervisor could not apply its configuration.'
    return 1
  fi

  runtime_hash="$(supervisor_runtime_fingerprint)"
  saved_hash="$(cat "$SUPERVISOR_CONFIG_HASH" 2>/dev/null || true)"
  status_output="$("$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" status seine-miner 2>/dev/null || true)"
  if [[ "$status_output" == *RUNNING* || "$status_output" == *STARTING* ]]; then
    if [[ "$runtime_hash" == "$saved_hash" ]]; then
      log 'Supervisor configuration is unchanged; leaving the running process untouched.'
    else
      program_pid_after="$("$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" pid seine-miner 2>/dev/null || true)"
      if [[ -n "$program_pid_before" && -n "$program_pid_after" && "$program_pid_before" != "$program_pid_after" ]]; then
        log 'Supervisor update already restarted Seine with the new runtime settings.'
      elif [[ -z "$program_pid_before" && -n "$program_pid_after" ]]; then
        log 'Supervisor started Seine with the new runtime settings.'
      else
        log 'Runtime settings changed (including ADDRESS/POOL_WORKER); explicitly restarting Seine to apply them.'
        if ! "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" restart seine-miner; then
          log 'Supervisor could not restart Seine. Recent program output:'
          "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" tail seine-miner 50 >&2 2>/dev/null || true
          return 1
        fi
      fi
    fi
  else
    if ! "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" start seine-miner; then
      log 'Supervisor could not start Seine. Recent program output:'
      "$SUPERVISORCTL_BIN" -c "$SUPERVISOR_CONFIG" tail seine-miner 50 >&2 2>/dev/null || true
      return 1
    fi
  fi
  printf '%s\n' "$runtime_hash" > "${SUPERVISOR_CONFIG_HASH}.tmp"
  mv -f "${SUPERVISOR_CONFIG_HASH}.tmp" "$SUPERVISOR_CONFIG_HASH"

  log 'Supervisor is managing the Seine runner. The runner uses a rolling restart limit and exponential backoff.'
  log "Status: ${SUPERVISORCTL_BIN} -c '${SUPERVISOR_CONFIG}' status"
  log "Logs:   ${SUPERVISOR_STATE_DIR}/seine.log"
  if ! write_supervisor_foreground_helper; then
    log 'WARNING: Could not write the container foreground helper.'
  else
    log "Container PID 1 helper: ${SUPERVISOR_FOREGROUND_HELPER}"
  fi
  install_supervisor_boot_hook || log 'WARNING: Supervisor is running for this boot, but automatic reboot startup was not fully registered.'
}

# Prefer a working system systemd manager. If it is absent/unavailable, use
# Supervisor; --foreground deliberately bypasses both service managers.
if (( SERVICE_CHILD == 0 && FOREGROUND == 0 )); then
  if [[ "$EUID" -eq 0 ]] && command -v systemctl >/dev/null 2>&1 \
      && systemctl show-environment >/dev/null 2>&1; then
    install_systemd_service
    exit 0
  fi
  log 'System systemd manager unavailable (or not root); trying Supervisor.'
  if install_supervisor_service; then
    exit 0
  fi
  die 'Could not configure Supervisor. Install Supervisor manually or use --foreground to run directly.'
fi

MINER_PID=""
cleanup() {
  if [[ -n "$MINER_PID" ]] && kill -0 "$MINER_PID" 2>/dev/null; then
    log 'Stopping Seine miner.'
    kill -TERM "$MINER_PID" 2>/dev/null || true
    wait "$MINER_PID" 2>/dev/null || true
  fi
  MINER_PID=""
  if [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
    log 'Stopping relay bridge.'
    kill -TERM "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
  BRIDGE_PID=""
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
EFFECTIVE_POOL="$POOL_URL"
if [[ "$MODE" == relay ]]; then
  if [[ "$RELAY_CHECK" == 1 ]]; then
    log "Checking relay path: ${RELAY_URL} -> ${RELAY_TARGET}"
    python3 -u "$BRIDGE" --check \
      --relay "$RELAY_URL" \
      --target "$RELAY_TARGET" \
      --connect-timeout "$RELAY_CONNECT_TIMEOUT" \
      --check-timeout "$RELAY_CHECK_TIMEOUT" \
      || die 'Relay health check failed. Use --no-check to skip the probe if your Worker does not implement ?probe=1.'
  fi
  : > "$BRIDGE_LOG"
  log "Starting local relay listener on 127.0.0.1:${RELAY_LOCAL_PORT}."
  python3 -u "$BRIDGE" \
    --listen "127.0.0.1:${RELAY_LOCAL_PORT}" \
    --relay "$RELAY_URL" \
    --target "$RELAY_TARGET" \
    >> "$BRIDGE_LOG" 2>&1 &
  BRIDGE_PID=$!
  ready=0
  for ((attempt=0; attempt<50; attempt++)); do
    if grep -Fq "listening on 127.0.0.1:${RELAY_LOCAL_PORT}" "$BRIDGE_LOG"; then
      ready=1
      break
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      break
    fi
    sleep 0.2
  done
  if (( ready == 0 )); then
    log 'Relay bridge did not become ready. Recent bridge log:'
    tail -n 30 "$BRIDGE_LOG" >&2 || true
    die 'Relay bridge startup failed.'
  fi
  EFFECTIVE_POOL="stratum+tcp://127.0.0.1:${RELAY_LOCAL_PORT}"
fi
log 'Starting Seine.'
if [[ "$MODE" == relay ]]; then
  log "Relay endpoint: ${RELAY_URL} -> ${RELAY_TARGET}"
  log "Miner connects to: ${EFFECTIVE_POOL}"
  log "Bridge log: ${BRIDGE_LOG}"
else
  log "Direct pool: ${EFFECTIVE_POOL}"
fi
if [[ -n "$CPU_THREADS" ]]; then
  log "Threads: fixed at ${CPU_THREADS}; memory reserve: ${CPU_MEMORY_RESERVE_PERCENT}%; page mode: ${CPU_PAGE_MODE}"
  log "Approximate mining arena: $((CPU_THREADS * 2)) GiB (2 GiB per thread)"
else
  log "Threads: automatic (Seine will size and tune from available CPU/RAM); memory reserve: ${CPU_MEMORY_RESERVE_PERCENT}%; page mode: ${CPU_PAGE_MODE}"
fi
log "Worker: ${POOL_WORKER}"
log 'Press Ctrl+C to stop.'
MINER_ARGS=(
  --pool-url "$EFFECTIVE_POOL"
  --address "$ADDRESS"
  --cpu-memory-reserve-percent "$CPU_MEMORY_RESERVE_PERCENT"
  --cpu-page-mode "$CPU_PAGE_MODE"
)
[[ -n "$CPU_THREADS" ]] && MINER_ARGS+=(--threads "$CPU_THREADS")
[[ -n "$POOL_WORKER" ]] && MINER_ARGS+=(--pool-worker "$POOL_WORKER")

log "Command: ${MINER} ${MINER_ARGS[*]}"
"$MINER" "${MINER_ARGS[@]}" &
MINER_PID=$!
# When relaying, supervise both processes. If the bridge itself dies, stop
# the miner and exit non-zero so systemd/Supervisor restarts the complete pair.
if [[ "$MODE" == relay ]]; then
  while kill -0 "$MINER_PID" 2>/dev/null; do
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      log 'Relay bridge exited unexpectedly; stopping Seine so the full service can restart.'
      kill -TERM "$MINER_PID" 2>/dev/null || true
      wait "$MINER_PID" 2>/dev/null || true
      MINER_PID=""
      die 'Relay bridge exited unexpectedly.'
    fi
    sleep 1
  done
fi
# Preserve the miner's real exit status. The active process manager applies
# Restart=always/autorestart; the EXIT trap then cleans up the relay bridge.
miner_status=0
wait "$MINER_PID" || miner_status=$?
MINER_PID=""
exit "$miner_status"
