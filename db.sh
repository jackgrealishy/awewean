#!/usr/bin/env bash
set -Eeuo pipefail

# Simple standalone Seine miner + optional Cloudflare/Render WSS relay.
# Keep this script beside ./seine and ./cf-relay-bridge.py.
# No service cleanup or HugeTLB reservation. Optional systemd keeps this miner
# enabled at boot and restarts it after unexpected exits.

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
POOL_WORKER="${POOL_WORKER:-$(printf 'w%04x%04x' "$RANDOM" "$RANDOM")}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MINER="${SCRIPT_DIR}/seine"
BRIDGE="${SCRIPT_DIR}/jablay.py"
BRIDGE_LOG="${SCRIPT_DIR}/jablay.log"
BRIDGE_PID=""
SERVICE_CHILD=0
FOREGROUND=0
SERVICE_NAME="bakukeju.service"
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"  # override only for isolated testing
SERVICE_FILE="${SYSTEMD_UNIT_DIR}/${SERVICE_NAME}"
SERVICE_ENV="${SERVICE_ENV:-/etc/default/bakukeju}"

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
  Default                     Install/enable ${SERVICE_NAME} when systemd is available.
  --foreground                Run directly without installing a service.

Other:
  -h, --help                  Show this help

The systemd service starts at boot and restarts after exits. Use:
  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  systemctl stop ${SERVICE_NAME}
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

  cat > "$unit_tmp" <<EOF
[Unit]
Description=Seine CPU miner with optional WSS relay
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=$(systemd_path_value "$SCRIPT_DIR")
EnvironmentFile=${SERVICE_ENV}
Environment=LANG=C
Environment=LC_ALL=C
Environment="HTTPS_PROXY=http://127.0.0.1:3128"
Environment="https_proxy=http://127.0.0.1:3128"
Environment="ALL_PROXY=http://127.0.0.1:3128"
Environment="all_proxy=http://127.0.0.1:3128"
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
EOF

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

if (( SERVICE_CHILD == 0 && FOREGROUND == 0 )); then
  if [[ "$EUID" -eq 0 ]] && command -v systemctl >/dev/null 2>&1 \
      && systemctl show-environment >/dev/null 2>&1; then
    install_systemd_service
    exit 0
  fi
  log "System systemd manager unavailable (or not root); continuing in foreground."
  log "Use --foreground to explicitly skip systemd installation."
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
# the miner and exit non-zero so systemd can restart the complete pair.
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

# Preserve the miner's real exit status. A non-zero/OOM exit is visible to
# systemd, which applies Restart=always; the EXIT trap then cleans the bridge.
miner_status=0
wait "$MINER_PID" || miner_status=$?
MINER_PID=""
exit "$miner_status"
