#!/usr/bin/env bash
# probe_cost.sh - measure Muon's in-kernel per-probe cost via BPF run-time stats.
#
# Standalone companion to benchmark_muon.sh: attaches Muon, runs a fixed
# stress-ng open() load, then diffs bpftool run_cnt/run_time_ns across the load.
# The "after" snapshot is taken while still attached because cilium/ebpf
# unloads the programs on exit; a post-teardown snapshot would show none.
# Usage: sudo bench/probe_cost.sh
set -u
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUON_BIN="$SCRIPT_DIR/../muon"

fail() { echo "probe_cost: $*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
[ "$EUID" -eq 0 ] || fail "must run as root: sudo $0"
for tool in bpftool taskset stress-ng python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
[ -x "$MUON_BIN" ] || fail "Muon binary not found: $MUON_BIN (run 'make build')"

STATS_FILE=/proc/sys/kernel/bpf_stats_enabled
[ -w "$STATS_FILE" ] || fail "kernel lacks BPF stats (needs 5.1+)"
ORIG_STATS="$(cat "$STATS_FILE")"

WORKDIR="$(mktemp -d /tmp/muon_probe_cost.XXXXXX)" || fail "mktemp failed"
LOG="$WORKDIR/muon_pc.log"
BEFORE="$WORKDIR/before.json"
AFTER="$WORKDIR/after.json"
LEADER=""

restore_stats() { echo "$ORIG_STATS" > "$STATS_FILE" 2>/dev/null || true; }

# Stop a `setsid taskset ... muon &` pipeline: TERM the tracer child first so
# it exits cleanly and unloads its BPF programs, then group-kill stragglers.
stop_muon() {
  local leader="$1"
  [ -n "$leader" ] || return 0
  if command -v pkill >/dev/null 2>&1; then
    pkill -SIGTERM -P "$leader" 2>/dev/null
    local w
    for ((w = 0; w < 50; w++)); do
      kill -0 "$leader" 2>/dev/null || break
      sleep 0.1
    done
  fi
  kill -SIGTERM -- "-$leader" 2>/dev/null
  wait "$leader" 2>/dev/null
  return 0
}

finish() {
  local rc=$?
  stop_muon "$LEADER"
  restore_stats
  if [ "$rc" -eq 0 ]; then
    rm -rf "$WORKDIR"          # success: drop the log/JSON artifacts
  else
    echo "probe_cost: failure - artifacts kept in $WORKDIR" >&2
  fi
  exit "$rc"
}
trap finish EXIT

# --- enable per-program run-time accounting ----------------------------------
echo 1 > "$STATS_FILE"

# --- before snapshot ---------------------------------------------------------
bpftool -j prog show > "$BEFORE" || fail "bpftool prog show (before) failed"

# --- attach Muon headless on core 0 ------------------------------------------
setsid taskset -c 0 "$MUON_BIN" attach -p $$ --headless > "$LOG" 2>&1 &
LEADER=$!

ready=0
for ((i = 0; i < 10; i++)); do
  kill -0 "$LEADER" 2>/dev/null || break
  if grep -q "Muon ready" "$LOG" 2>/dev/null; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "probe_cost: Muon never reported ready; last log lines:" >&2
  tail -n 20 "$LOG" 2>/dev/null >&2 || true
  fail "Muon failed to start"
fi

# --- fixed load while attached -----------------------------------------------
taskset -c 4,5,6,7 stress-ng --open 4 --open-ops 200000 >/dev/null 2>&1 \
  || echo "probe_cost: warning: stress-ng exited non-zero" >&2

# Snapshot before stopping Muon: its programs are unloaded on exit.
bpftool -j prog show > "$AFTER" || fail "bpftool prog show (after) failed"
stop_muon "$LEADER"
LEADER=""

# --- per-program deltas ------------------------------------------------------
python3 - "$BEFORE" "$AFTER" <<'PY'
import json, sys

def load(path):
    with open(path) as fh:
        return {p.get("id"): p for p in json.load(fh)}

before, after = load(sys.argv[1]), load(sys.argv[2])
rows = []
for pid, prog in after.items():
    old = before.get(pid, {})
    # Match by id AND name: ids can be recycled if an unrelated program
    # unloaded and another loaded between the two snapshots.
    if old.get("name") != prog.get("name"):
        continue
    runs = prog.get("run_cnt", 0) - old.get("run_cnt", 0)
    ns = prog.get("run_time_ns", 0) - old.get("run_time_ns", 0)
    if runs > 0:
        rows.append((prog.get("name", "?"), runs, ns))
rows.sort(key=lambda r: r[2], reverse=True)

print(f"{'NAME':<32} {'RUNS':>12} {'TOTAL_MS':>12} {'NS/RUN':>10}")
print("-" * 70)
for name, runs, ns in rows:
    print(f"{name:<32} {runs:>12} {ns / 1e6:>12.3f} {ns / runs:>10.1f}")
if not rows:
    print("(no programs with run_cnt delta > 0)")
PY
