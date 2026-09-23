#!/usr/bin/env bash
# probe_cost.sh: Muon's in-kernel per-probe cost via BPF run-time stats.
# Attaches Muon, runs a fixed open() load, diffs bpftool run_cnt/run_time_ns.
# Attribution is by attach-time program id set, so unrelated system BPF
# programs can't pollute the table. The "after" snapshot precedes teardown
# because exiting unloads the programs.
# Usage: sudo bench/probe_cost.sh
set -u
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUON_BIN="$SCRIPT_DIR/../muon"

fail() { echo "probe_cost: $*" >&2; exit 1; }

# --- preconditions -----------------------------------------------------------
[ "$EUID" -eq 0 ] || fail "must run as root: sudo $0"
for tool in bpftool taskset stress-ng python3 setsid; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
[ -x "$MUON_BIN" ] || fail "Muon binary not found: $MUON_BIN (run 'make build')"
if command -v pkill >/dev/null 2>&1; then PKILL_OK=1; else PKILL_OK=0; fi

# Shared teardown lives in lib.sh (graceful TERM first so `time`/tally
# equivalents complete, SIGKILL escalation, no orphaned tracers).
LIB_SH="$SCRIPT_DIR/lib.sh"
[ -f "$LIB_SH" ] || fail "lib.sh missing at $LIB_SH"
# shellcheck disable=SC1091
. "$LIB_SH"

STATS_FILE=/proc/sys/kernel/bpf_stats_enabled
[ -w "$STATS_FILE" ] || fail "kernel lacks BPF stats (needs 5.1+)"
ORIG_STATS="$(cat "$STATS_FILE")"

WORKDIR="$(mktemp -d /tmp/muon_probe_cost.XXXXXX)" || fail "mktemp failed"
LOG="$WORKDIR/muon_pc.log"
BEFORE="$WORKDIR/before.json"
MID="$WORKDIR/mid.json"
AFTER="$WORKDIR/after.json"
LEADER=""

restore_stats() { echo "$ORIG_STATS" > "$STATS_FILE" 2>/dev/null || true; }

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

# Mid snapshot defines Muon's id set; name matching below guards against
# kernel id recycling between snapshots.
bpftool -j prog show > "$MID" || fail "bpftool prog show (mid) failed"

# --- fixed load while attached -----------------------------------------------
# A failed load invalidates the measurement (near-zero deltas would print
# as a clean-looking empty table with exit 0).
taskset -c 4,5,6,7 stress-ng --open 4 --open-ops 200000 >/dev/null 2>&1 \
  || fail "stress-ng load failed (artifacts kept in $WORKDIR)"

# Snapshot before stopping Muon: its programs are unloaded on exit.
bpftool -j prog show > "$AFTER" || fail "bpftool prog show (after) failed"
stop_muon "$LEADER"
LEADER=""

# --- per-program deltas ------------------------------------------------------
python3 - "$BEFORE" "$MID" "$AFTER" <<'PY'
import json, sys

def load(path):
    with open(path) as fh:
        data = json.load(fh)
    if not isinstance(data, list):
        raise ValueError(f"{path}: expected a JSON list from 'bpftool -j prog show'")
    return {p.get("id"): p for p in data if isinstance(p, dict)}

def num(prog, key):
    val = prog.get(key)
    return val if isinstance(val, int) and not isinstance(val, bool) else 0

before, mid, after = (load(p) for p in sys.argv[1:4])

# Muon's ids: fresh at attach, plus recycled ids renamed to trace_*.
# Deltas are mid→after (the load window); vanished/renamed ids are skipped.
muon_ids = {}
for pid, prog in mid.items():
    name = prog.get("name", "?")
    if pid not in before:
        muon_ids[pid] = name
    elif before[pid].get("name") != name and isinstance(name, str) and name.startswith("trace_"):
        muon_ids[pid] = name
rows = []
for pid, name in muon_ids.items():
    old, prog = mid.get(pid, {}), after.get(pid)
    if prog is None or prog.get("name") != name:
        continue
    runs = num(prog, "run_cnt") - num(old, "run_cnt")
    ns = num(prog, "run_time_ns") - num(old, "run_time_ns")
    if runs > 0:
        rows.append((name, runs, ns))
rows.sort(key=lambda r: r[2], reverse=True)

print(f"{'NAME':<32} {'RUNS':>12} {'TOTAL_MS':>12} {'NS/RUN':>10}")
print("-" * 70)
for name, runs, ns in rows:
    print(f"{name:<32} {runs:>12} {ns / 1e6:>12.3f} {ns / runs:>10.1f}")
if not rows:
    print("(no programs with run_cnt delta > 0)")
PY
