#!/usr/bin/env bash
# probe_cost.sh - measure Muon's in-kernel per-probe cost via BPF run-time stats.
#
# Standalone companion to benchmark_muon.sh: attaches Muon, runs a fixed
# stress-ng open() load, then diffs bpftool run_cnt/run_time_ns across the load.
# Attribution is by program id set: ids present after attach but absent before
# are Muon's, so unrelated system BPF programs can never pollute the table.
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
for tool in bpftool taskset stress-ng python3 setsid; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done
[ -x "$MUON_BIN" ] || fail "Muon binary not found: $MUON_BIN (run 'make build')"

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

# Mid snapshot: program ids present here but absent from BEFORE are Muon's.
# (An id present in both could theoretically have been recycled between the
# snapshots; matching by id AND name below keeps that from attributing
# another program's runs to Muon.)
bpftool -j prog show > "$MID" || fail "bpftool prog show (mid) failed"

# --- fixed load while attached -----------------------------------------------
# A failed load invalidates the whole measurement: deltas near zero would
# otherwise print as a clean-looking empty table with exit 0.
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

# Muon's programs are the ids that appear at attach time: fresh ids absent
# from BEFORE, plus recycled ids whose name changed to a trace_* program
# (Muon's C functions are all trace_*; bpftool truncates to 15 chars).
# Deltas are mid→after (the load window); an id that vanished or changed
# names again since is unattributable and skipped.
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
