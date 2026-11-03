#!/usr/bin/env bash
set -Eeuo pipefail

# Simple standalone Seine miner + optional Cloudflare/Render WSS relay.
# Keep this script beside ./seine and ./cf-relay-bridge.py.
# No service cleanup, systemd installation, boot persistence, or HugeTLB setup.

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
CPU_THREADS="${CPU_THREADS:-4}"
CPU_MEMORY_RESERVE_PERCENT="${CPU_MEMORY_RESERVE_PERCENT:-0}"
# Use auto because this runtime did not expose HugeTLB information.
# Seine may use the best page mode available on the host.
CPU_PAGE_MODE="${CPU_PAGE_MODE:-auto}"
POOL_WORKER="${POOL_WORKER:-$(printf 'w%04x%04x' "$RANDOM" "$RANDOM")}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MINER="${SCRIPT_DIR}/seine"
BRIDGE="${SCRIPT_DIR}/cf-relay-bridge.py"
BRIDGE_LOG="${SCRIPT_DIR}/cf-relay-bridge.log"
BRIDGE_PID=""

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
  --no-check                Skip relay -> pool probe
  --check                   Enable relay -> pool probe

Mining:
  --address ADDRESS         Payout address
  --threads N               CPU threads (default: ${CPU_THREADS})
  --cpu-memory-reserve-percent N  RAM reserve percent (default: ${CPU_MEMORY_RESERVE_PERCENT})
  --page-mode MODE          auto, regular, large, large-1g (default: ${CPU_PAGE_MODE})
  --pool-worker NAME        Worker label (default: ${POOL_WORKER})

Other:
  -h, --help                Show this help

This is a foreground launcher. Press Ctrl+C to stop Seine and the relay bridge.
USAGE
}

while (($#)); do
  case "$1" in
    --mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
    --relay) RELAY_URL="${2:?--relay requires a URL}"; shift 2 ;;
    --target) RELAY_TARGET="${2:?--target requires HOST:PORT}"; shift 2 ;;
    --pool) POOL_URL="${2:?--pool requires a URL}"; shift 2 ;;
    --local-port) RELAY_LOCAL_PORT="${2:?--local-port requires a port}"; shift 2 ;;
    --address) ADDRESS="${2:?--address requires a value}"; shift 2 ;;
    --threads) CPU_THREADS="${2:?--threads requires a number}"; shift 2 ;;
    --cpu-memory-reserve-percent) CPU_MEMORY_RESERVE_PERCENT="${2:?--cpu-memory-reserve-percent requires a number}"; shift 2 ;;
    --page-mode) CPU_PAGE_MODE="${2:?--page-mode requires a value}"; shift 2 ;;
    --pool-worker) POOL_WORKER="${2:?--pool-worker requires a value}"; shift 2 ;;
    --check) RELAY_CHECK=1; shift ;;
    --no-check) RELAY_CHECK=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

case "$MODE" in relay|direct) ;; *) die "--mode must be relay or direct" ;; esac
case "$RELAY_CHECK" in 0|1) ;; *) die "RELAY_CHECK must be 0 or 1" ;; esac
[[ "$CPU_THREADS" =~ ^[1-9][0-9]*$ ]] || die "--threads must be a positive integer"
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
