# bench/lib.sh — shared shell helpers, sourced by benchmark_muon.sh and
# bench/probe_cost.sh. Sourced, never executed. Requires bash 4+.
# shellcheck disable=SC2148

# Abort unless every tool in the space-separated list exists.
require_tool() {
  local t
  for t in $1; do
    command -v "$t" >/dev/null 2>&1 || {
      echo "ABORT: required tool '$t' not found in PATH." >&2
      exit 1
    }
  done
}

# Map non-alphanumerics so names/tags can't escape /tmp or shift CSV columns.
safe_str() {
  printf '%s' "$1" | tr -c '[:alnum:]_' '_'
}

# Last KEY=value from a probe file (empty when missing); subshell-safe channel.
tally() {
  [ -r "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# Stop a `setsid taskset ... time ... muon &` pipeline ($1 = leader = PGID).
# TERM the tracer first so it tallies and `time` writes its report, group-kill
# stragglers after, SIGKILL escalation so a wedged tracer never hangs us.
# (Killing just $! would orphan a still-tracing Muon.)
stop_muon() {
  local leader="$1"
  [ -n "$leader" ] || return 0
  if [[ "${PKILL_OK:-0}" -eq 1 ]]; then
    pkill -SIGTERM -P "$leader" 2>/dev/null
    local w
    for ((w=0; w<50; w++)); do
      kill -0 "$leader" 2>/dev/null || break
      sleep 0.1
    done
  fi
  kill -SIGTERM -- "-$leader" 2>/dev/null
  local w2
  for ((w2=0; w2<10; w2++)); do
    kill -0 "$leader" 2>/dev/null || break
    sleep 0.1
  done
  kill -SIGKILL -- "-$leader" 2>/dev/null
  wait "$leader" 2>/dev/null
  [ -n "${LIVE_PGID_FILE:-}" ] && rm -f "$LIVE_PGID_FILE"
  return 0
}
