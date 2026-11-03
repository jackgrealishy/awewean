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
if [[ ! -x "$MINER" ]]; then
  chmod +x "$MINER" || die "Cannot make Seine executable: $MINER"
fi
if [[ "$MODE" == relay ]]; then
  command -v python3 >/dev/null 2>&1 || die "python3 is required for relay mode"
  [[ -f "$BRIDGE" ]] || die "Relay bridge not found: $BRIDGE (place cf-relay-bridge.py beside this script)"
fi

cleanup() {
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
log "Threads: ${CPU_THREADS}; memory reserve: ${CPU_MEMORY_RESERVE_PERCENT}%; page mode: ${CPU_PAGE_MODE}"
log "Approximate mining arena: $((CPU_THREADS * 2)) GiB (2 GiB per thread)"
log "Worker: ${POOL_WORKER}"
log 'Press Ctrl+C to stop.'

MINER_ARGS=(
  --pool-url "$EFFECTIVE_POOL"
  --address "$ADDRESS"
  --threads "$CPU_THREADS"
  --cpu-memory-reserve-percent "$CPU_MEMORY_RESERVE_PERCENT"
  --cpu-page-mode "$CPU_PAGE_MODE"
)
[[ -n "$POOL_WORKER" ]] && MINER_ARGS+=(--pool-worker "$POOL_WORKER")

log "Command: ${MINER} ${MINER_ARGS[*]}"
"$MINER" "${MINER_ARGS[@]}"
