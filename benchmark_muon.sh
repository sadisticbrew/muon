#!/bin/bash
# =============================================================================
# Muon Benchmark Suite - Fair, Reproducible & Mathematically Sound
# =============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./benchmark_muon.sh"
  exit 1
fi

export LC_NUMERIC=C

MUON_BIN="./muon"
RESULTS_FILE="/tmp/muon_bench_results.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# CPU Core Pinning
WORKLOAD_CORES="4,5,6,7"
MUON_CORE="0"

# Dev mode vs Full mode
FAST_MODE=0
MUON_ONLY=0
TRACERS_ONLY=0
PUBLICATION=0
WARMUP=0
SWEEP=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    --muon-only) MUON_ONLY=1 ;;
    --tracers-only) TRACERS_ONLY=1 ;;
    --publication) PUBLICATION=1 ;;
    --sweep) SWEEP=1 ;;
    *)
      echo "Unknown option: $arg (supported: --fast, --muon-only, --tracers-only, --publication, --sweep)"
      exit 1
      ;;
  esac
done

if [[ "$FAST_MODE" -eq 1 ]]; then
    ITERATIONS=5
    EXEC_OPS=1000
    OPEN_OPS=100000
    MMAP_OPS=1000

    # Mixed mode needs specific ops per stressor
    MIXED_EXEC_OPS=200
    MIXED_OPEN_OPS=20000
    MIXED_MMAP_OPS=500

    WARMUP=1

    echo "============================================="
    echo " Muon Benchmark Suite [FAST DEV MODE]"
    echo "============================================="
else
    ITERATIONS=10
    EXEC_OPS=10000
    OPEN_OPS=300000
    MMAP_OPS=15000

    MIXED_EXEC_OPS=2000
    MIXED_OPEN_OPS=100000
    MIXED_MMAP_OPS=5000

    WARMUP=2

    echo "============================================="
    echo " Muon Benchmark Suite [FULL MODE]"
    echo "============================================="
fi

if [[ "$PUBLICATION" -eq 1 ]]; then
  echo " PUBLICATION MODE — includes the kernel-compile workload"
fi

if [[ "$SWEEP" -eq 1 ]]; then
  echo " SWEEP MODE — capacity scan runs after the standard categories"
fi

# Muon-only mode keeps its own results file so it never clobbers a full run.
if [[ "$MUON_ONLY" -eq 1 ]]; then
  RESULTS_FILE="/tmp/muon_bench_muon_only.txt"
  echo " MUON ONLY — baseline/strace/perf trace skipped, no overhead% in summary"
fi

# Tracers-only mode also keeps its own results file.
if [[ "$TRACERS_ONLY" -eq 1 ]]; then
  RESULTS_FILE="/tmp/muon_bench_tracers_only.txt"
  echo " TRACERS ONLY — baseline and Muon skipped, no overhead% in summary"
fi

> "$RESULTS_FILE"

# Drop stale per-run artifacts from any earlier session so no leftover
# .times/.log/.txt file can ever bleed into this session's measurements.
rm -f /tmp/muon_*.log /tmp/muon_res_*.txt /tmp/muon_workload_err_*.txt \
  /tmp/muon_cell_*.times /tmp/muon_lastres.txt /tmp/muon_time.txt \
  /tmp/muon_lastevents.txt

# Save each CPU's current governor so restore_governors() can put it back.
declare -A SAVED_GOVERNORS=()
for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -r "$gov_file" ] || continue
  governor=$(cat "$gov_file" 2>/dev/null)
  [ -n "$governor" ] && SAVED_GOVERNORS["$gov_file"]="$governor"
  echo performance > "$gov_file" 2>/dev/null
done

restore_governors() {
  local gov_file
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "${SAVED_GOVERNORS["$gov_file"]:-powersave}" > "$gov_file" 2>/dev/null
  done
}
trap restore_governors EXIT

# =============================================================================
# HYBRID-CORE PINNING SANITY CHECK
# =============================================================================

cpu_freq_khz() {
  local cpu="$1"
  local base="/sys/devices/system/cpu/cpu${cpu}/cpufreq/base_frequency"
  local maxf="/sys/devices/system/cpu/cpu${cpu}/cpufreq/cpuinfo_max_freq"
  if [ -r "$base" ]; then
    cat "$base" 2>/dev/null
  elif [ -r "$maxf" ]; then
    cat "$maxf" 2>/dev/null
  else
    echo "unknown"
  fi
}

IFS=',' read -r -a WORKLOAD_CORE_LIST <<< "$WORKLOAD_CORES"
WORKLOAD_FREQS=()
for core in "${WORKLOAD_CORE_LIST[@]}"; do
  WORKLOAD_FREQS+=("$(cpu_freq_khz "$core")")
done

heterogeneous=0
for idx in "${!WORKLOAD_FREQS[@]}"; do
  if [ "${WORKLOAD_FREQS[$idx]}" != "${WORKLOAD_FREQS[0]}" ]; then
    heterogeneous=1
    break
  fi
done

if [ "$heterogeneous" -eq 1 ]; then
  echo "ABORT: workload cores ${WORKLOAD_CORES} are heterogeneous in frequency:" >&2
  for idx in "${!WORKLOAD_CORE_LIST[@]}"; do
    echo "  cpu${WORKLOAD_CORE_LIST[$idx]}: ${WORKLOAD_FREQS[$idx]} kHz" >&2
  done
  echo "Pin WORKLOAD_CORES to cores of equal base/max frequency and retry." >&2
  exit 1
fi

MUON_FREQ=$(cpu_freq_khz "$MUON_CORE")
CORE_MAP_LINE="coremap: workload=${WORKLOAD_CORES}@${WORKLOAD_FREQS[0]} muon=${MUON_CORE}@${MUON_FREQ}"
echo "$CORE_MAP_LINE" >> "$RESULTS_FILE"
echo "$CORE_MAP_LINE"

# =============================================================================
# ENVIRONMENT DUMP (separate .env file next to the results; never the CSV)
# =============================================================================

ENV_FILE="${RESULTS_FILE%.txt}.env"
{
  echo "== Environment =="
  echo "kernel: $(uname -r)"
  echo "cpu: $(lscpu 2>/dev/null | grep 'Model name' | sed 's/^[[:space:]]*//')"
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -r "$gov_file" ] || continue
    echo "governor $(basename "$(dirname "$(dirname "$gov_file")")"): $(cat "$gov_file" 2>/dev/null)"
  done
  if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    echo "turbo: intel_pstate/no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
  elif [ -r /sys/devices/system/cpu/cpufreq/boost ]; then
    echo "turbo: cpufreq/boost=$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"
  else
    echo "turbo: no intel_pstate/no_turbo or cpufreq/boost knob present"
  fi
  for vuln in /sys/devices/system/cpu/vulnerabilities/*; do
    [ -r "$vuln" ] || continue
    echo "mitigation $(basename "$vuln"): $(cat "$vuln" 2>/dev/null)"
  done
  echo "muon git sha: $(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "muon git dirty (first 3 lines):"
  git -C "$SCRIPT_DIR" status --short 2>/dev/null | head -3
  echo "muon binary sha256: $(sha256sum "$MUON_BIN" 2>/dev/null || echo unavailable)"
} > "$ENV_FILE" 2>&1
cat "$ENV_FILE"

# =============================================================================
# POWER / THERMAL GUARDS
# =============================================================================

# Full runs must be on AC; --fast dev runs on battery are allowed with a warning.
# Machines without power_supply entries proceed with a warning.
check_power_supply() {
  local online_files=(/sys/class/power_supply/*/online)
  if [ ! -e "${online_files[0]}" ]; then
    echo "WARNING: no /sys/class/power_supply/*/online entries found — cannot verify AC power."
    return 0
  fi

  local ac_online=0 supply
  for supply in "${online_files[@]}"; do
    [ -r "$supply" ] || continue
    if [ "$(cat "$supply" 2>/dev/null)" = "1" ]; then
      ac_online=1
      break
    fi
  done

  if [ "$ac_online" -eq 0 ]; then
    if [ "$FAST_MODE" -eq 1 ]; then
      echo "WARNING: no AC supply online (on battery) — --fast mode, timings may be noisy."
    else
      echo "ABORT: no AC supply online (running on battery). Plug in AC or rerun with --fast." >&2
      exit 1
    fi
  fi
}

# Abort when any thermal zone is above 95°C so throttled numbers are never recorded.
check_thermal() {
  local max_temp=0 zone temp
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    temp=$(cat "$zone" 2>/dev/null)
    [[ "$temp" =~ ^[0-9]+$ ]] || continue
    if [ "$temp" -gt "$max_temp" ]; then
      max_temp="$temp"
    fi
  done

  if [ "$max_temp" -gt 95000 ]; then
    echo "ABORT: thermal zone at $((max_temp / 1000))°C (>95°C) — refusing to record throttled results." >&2
    exit 1
  fi
}

check_power_supply

# The exec workload drops privileges via sudo; with SUDO_USER empty every
# exec run fails and the session would die at the first warmup. Fail here
# with an actionable message instead.
if [ -z "${SUDO_USER:-}" ]; then
  echo "ABORT: SUDO_USER is empty — run via 'sudo ./benchmark_muon.sh ...' from your user account, not from a root shell." >&2
  exit 1
fi

# =============================================================================
# STATS HELPER
# =============================================================================

calculate_stats() {
  local values=("$@")
  local count=${#values[@]}

  if [ "$count" -lt 3 ]; then
    echo "0.000 0.000 0.000 0.000"
    return 1
  fi

  local sorted=($(printf '%s\n' "${values[@]}" | sort -n))
  local trimmed=("${sorted[@]:1:$((count - 2))}")

  printf '%s\n' "${trimmed[@]}" | awk '{
    sum += $1;
    sumsq += ($1 * $1);
    n++;
    if (n == 1 || $1 < tmin) tmin = $1;
    if (n == 1 || $1 > tmax) tmax = $1;
  } END {
    if (n > 0) {
      mean = sum / n;
      variance = (sumsq / n) - (mean * mean);
      if (variance < 0) variance = 0;
      printf "%.3f %.3f %.3f %.3f", mean, sqrt(variance), tmin, tmax;
    } else {
      printf "0.000 0.000 0.000 0.000";
    }
  }'
}

# =============================================================================
# CORE BENCHMARK FUNCTION
# =============================================================================

# Skip rules shared by every category: muon-only runs only "Muon";
# tracers-only skips both "Baseline" and "Muon".
cell_active() {
  if [[ "$MUON_ONLY" -eq 1 && "$1" != "Muon" ]]; then
    return 1
  fi
  if [[ "$TRACERS_ONLY" -eq 1 && ( "$1" == "Baseline" || "$1" == "Muon" ) ]]; then
    return 1
  fi
  return 0
}

# Per-cell state keyed by "<category>|<name>". Wall times live in
# /tmp/muon_cell_<category>_<safe_name>.times so interleaved rounds never lose
# a measurement, and dropped counts survive across the round loop.
declare -A CELL_DROPPED=()
declare -A CELL_CPU_SUM=()
declare -A CELL_CPU_COUNT=()
declare -A CELL_RSS_MAX=()

# Stop a tracer pipeline started as `setsid taskset ... time ... muon &`.
# $1 is the pipeline leader PID, which (via setsid) is also its PGID.
# Order matters: TERM the tracer (time's child) FIRST so it can print its
# shutdown tally and — critically — so `time` observes a normal child exit
# and writes its -v report. Only then group-kill any stragglers. Killing the
# group outright would take `time` down before it writes the report (losing
# CPU/RSS figures) — and killing just the leader would orphan the tracer.
stop_muon() {
  local leader="$1"
  [ -n "$leader" ] || return 0
  if command -v pkill >/dev/null 2>&1; then
    pkill -SIGTERM -P "$leader" 2>/dev/null
    local w
    for ((w=0; w<50; w++)); do
      kill -0 "$leader" 2>/dev/null || break
      sleep 0.1
    done
  fi
  kill -SIGTERM -- "-$leader" 2>/dev/null
  wait "$leader" 2>/dev/null
  return 0
}

# =============================================================================
# SINGLE RUN HELPER
# =============================================================================

# Executes one full iteration: drop caches, start Muon (if any), wait for
# readiness, run the workload, stop Muon. In timed mode the measured wall time
# is echoed on stdout; diagnostics always go to stderr.
# Returns:
#   0 = clean run
#   1 = Muon failed to become ready (run dropped)
#   2 = invalid timing output (run dropped)
#   3 = ring buffer full warning (run dropped)
#   4 = Muon ran but observed zero events (run dropped)
#   5 = workload command itself failed (run dropped)
# When bg_cmd is set, Muon runs under /usr/bin/time -v and its CPU%/max-RSS
# are published via /tmp/muon_lastres.txt (a file, because callers invoke this
# function inside a command-substitution subshell that cannot export vars).
single_run() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local timed="$5"
  local tag="$6"
  local safe_name="${name// /_}"
  local safe_tag="${tag// /_}"

  sync
  echo 3 > /proc/sys/vm/drop_caches
  sleep 0.5

  local muon_pid=""
  local muon_log="/tmp/muon_${safe_tag}.log"
  local muon_res="/tmp/muon_res_${safe_tag}.txt"
  if [ -n "$bg_cmd" ]; then
    rm -f "$muon_res"
    # setsid puts the whole tracer pipeline (taskset/time/muon) in its own
    # process group so teardown can signal ALL of it: killing just $! would
    # take down `time` and orphan a still-tracing Muon on every run, leaking
    # tracers that contaminate later cells and defeat drop/event detection.
    setsid taskset -c "$MUON_CORE" /usr/bin/time -v -o "$muon_res" $bg_cmd > "$muon_log" 2>&1 &
    muon_pid=$!
  fi

  sleep 1

  if [ -n "$muon_pid" ]; then
    if ! kill -0 "$muon_pid" 2>/dev/null; then
      echo "  $tag: FATAL — Muon exited before the run started:" >&2
      tail -n 10 "$muon_log" | sed 's/^/    /' >&2
      stop_muon "$muon_pid"
      printf 'MUON_EVENTS=\n' > /tmp/muon_lastevents.txt
      rm -f "$muon_log"
      return 1
    fi
    if ! grep -q "Muon ready" "$muon_log" 2>/dev/null; then
      echo "  $tag: FATAL — Muon never reported ready:" >&2
      tail -n 10 "$muon_log" | sed 's/^/    /' >&2
      stop_muon "$muon_pid"
      printf 'MUON_EVENTS=\n' > /tmp/muon_lastevents.txt
      rm -f "$muon_log"
      return 1
    fi
  fi

  # /usr/bin/time reports %e into muon_time.txt via -o, while the workload's
  # own stderr goes to a per-run file, so the two streams never mix. Clear the
  # timing file first so a failed/missing time never leaves stale values.
  rm -f /tmp/muon_time.txt
  local workload_err="/tmp/muon_workload_err_${safe_name}_${safe_tag}.txt"
  # Workload stdout is discarded: it would otherwise flow into this function's
  # stdout and contaminate the caller's $(...) capture (stress-ng prints its
  # own summary to stdout). Timing comes from muon_time.txt, diagnostics from
  # the stderr file — stdout is needed by nothing.
  # /usr/bin/time propagates the workload's exit status, so a silently
  # failing workload (bad flags, missing binary, OOM) can never masquerade
  # as a fast valid run.
  local workload_rc=0
  if [ -n "$prefix_cmd" ]; then
    /usr/bin/time -f "%e" -o /tmp/muon_time.txt \
      taskset -c "$WORKLOAD_CORES" $prefix_cmd bash -c "$workload" \
      >/dev/null 2> "$workload_err"
    workload_rc=$?
  else
    /usr/bin/time -f "%e" -o /tmp/muon_time.txt \
      taskset -c "$WORKLOAD_CORES" bash -c "$workload" \
      >/dev/null 2> "$workload_err"
    workload_rc=$?
  fi

  local drop_warning=0
  local zero_events=0
  if [ -n "$muon_pid" ]; then
    stop_muon "$muon_pid"

    # Extract Muon's CPU%/max-RSS from /usr/bin/time -v. Missing or malformed
    # fields simply become empty and never change this run's return code.
    local muon_cpu="" muon_rss=""
    if [ -r "$muon_res" ]; then
      local cpu_line rss_line
      cpu_line=$(grep -m1 'Percent of CPU this job got:' "$muon_res" 2>/dev/null)
      rss_line=$(grep -m1 'Maximum resident set size (kbytes):' "$muon_res" 2>/dev/null)
      cpu_line="${cpu_line##*: }"
      cpu_line="${cpu_line%\%}"
      rss_line="${rss_line##*: }"
      [[ "$cpu_line" =~ ^[0-9]+$ ]] || cpu_line=""
      [[ "$rss_line" =~ ^[0-9]+$ ]] || rss_line=""
      muon_cpu="$cpu_line"
      muon_rss="$rss_line"
    fi
    printf 'MUON_CPU=%s\nMUON_RSS=%s\n' "$muon_cpu" "$muon_rss" > /tmp/muon_lastres.txt

    if grep -q "WARNING: Ring buffer was full" "$muon_log" 2>/dev/null; then
      drop_warning=1
    fi
    # The last EVENTS: tally printed on shutdown is authoritative for this
    # run; a missing line or total=0 means Muon observed nothing. The parsed
    # total is also published to /tmp/muon_lastevents.txt (the caller runs in a
    # subshell, so files are the communication channel). Non-Muon runs never
    # reach this block and never touch the file.
    local last_events
    last_events=$(grep "EVENTS:" "$muon_log" 2>/dev/null | tail -n 1)
    if [[ "$last_events" =~ total=([0-9]+) ]]; then
      printf 'MUON_EVENTS=%s\n' "${BASH_REMATCH[1]}" > /tmp/muon_lastevents.txt
      [ "${BASH_REMATCH[1]}" -gt 0 ] || zero_events=1
    else
      printf 'MUON_EVENTS=\n' > /tmp/muon_lastevents.txt
      zero_events=1
    fi
    rm -f "$muon_log"
  fi

  if [ "$workload_rc" -ne 0 ]; then
    echo "  $tag: FATAL — workload exited rc=$workload_rc (dropping run):" >&2
    tail -n 5 "$workload_err" 2>/dev/null | sed 's/^/    /' >&2
    return 5
  fi

  if [ "$zero_events" -eq 1 ]; then
    return 4
  fi

  if [ "$timed" -eq 0 ]; then
    return 0
  fi

  local run_time
  run_time=$(tail -n 1 /tmp/muon_time.txt)
  if [[ ! "$run_time" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "  $tag: FATAL — invalid timing output (dropping run):" >&2
    sed 's/^/    /' /tmp/muon_time.txt >&2
    return 2
  fi

  echo "$run_time"

  if [ "$drop_warning" -eq 1 ]; then
    return 3
  fi

  return 0
}

# Untimed warmup for one cell: WARMUP iterations via single_run, timing
# discarded. Reports failure to the caller (which decides abort vs disable)
# instead of exiting. Also truncates the cell's times file so runs from an
# earlier session can never bleed into this one.
warm_cell() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local category="$5"
  local safe_name="${name// /_}"
  local times_file="/tmp/muon_cell_${category}_${safe_name}.times"

  : > "$times_file"

  echo ""
  echo "--- $name ---"

  local w=0 warm_rc=0
  for ((w = 1; w <= WARMUP; w++)); do
    warm_rc=0
    single_run "$name" "$prefix_cmd" "$bg_cmd" "$workload" 0 "Warmup $w" || warm_rc=$?
    if [ "$warm_rc" -ne 0 ]; then
      echo ">> CELL FAILED: warmup $w/$WARMUP failed (rc=$warm_rc) for $name. <<" >&2
      return 1
    fi
    echo "  Warmup $w/$WARMUP: complete (timing discarded)"
  done
}

# One timed iteration for one cell inside the round-robin. A valid wall time is
# appended to the cell's times file; any failure bumps the per-cell dropped
# counter. After a clean Muon run the resource figures published by single_run
# in /tmp/muon_lastres.txt are folded into the per-cell accumulators.
timed_round() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local category="$5"
  local round="$6"
  local key="$category|$name"
  local safe_name="${name// /_}"
  local times_file="/tmp/muon_cell_${category}_${safe_name}.times"

  local run_out="" run_rc=0
  run_out=$(single_run "$name" "$prefix_cmd" "$bg_cmd" "$workload" 1 "Run $round") || run_rc=$?

  if [ "$run_rc" -eq 3 ]; then
    echo "  Run $round: ${run_out}s [DROPPED — ring buffer full]"
    CELL_DROPPED["$key"]=$(( ${CELL_DROPPED["$key"]:-0} + 1 ))
    return
  fi
  if [ "$run_rc" -ne 0 ]; then
    CELL_DROPPED["$key"]=$(( ${CELL_DROPPED["$key"]:-0} + 1 ))
    return
  fi

  # Belt and braces: only a clean numeric timing may enter the times file.
  if [[ ! "$run_out" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "  Run $round: non-numeric timing captured (dropping run)" >&2
    CELL_DROPPED["$key"]=$(( ${CELL_DROPPED["$key"]:-0} + 1 ))
    return
  fi

  echo "  Run $round: ${run_out}s"
  echo "$run_out" >> "$times_file"

  if [ -n "$bg_cmd" ]; then
    local muon_cpu="" muon_rss=""
    if [ -r /tmp/muon_lastres.txt ]; then
      muon_cpu=$(sed -n 's/^MUON_CPU=//p' /tmp/muon_lastres.txt | tail -n 1)
      muon_rss=$(sed -n 's/^MUON_RSS=//p' /tmp/muon_lastres.txt | tail -n 1)
    fi
    if [[ "$muon_cpu" =~ ^[0-9]+$ ]]; then
      CELL_CPU_SUM["$key"]=$(( ${CELL_CPU_SUM["$key"]:-0} + muon_cpu ))
      CELL_CPU_COUNT["$key"]=$(( ${CELL_CPU_COUNT["$key"]:-0} + 1 ))
    fi
    if [[ "$muon_rss" =~ ^[0-9]+$ ]]; then
      if [ -z "${CELL_RSS_MAX["$key"]:-}" ] || [ "$muon_rss" -gt "${CELL_RSS_MAX["$key"]}" ]; then
        CELL_RSS_MAX["$key"]="$muon_rss"
      fi
    fi
  fi
}

# Reads a cell's times file, computes stats and appends exactly ONE CSV row.
#
# CSV format v2 (10 comma-separated fields, one row per cell):
#   category,name,avg,stddev,min,max,valid,dropped,muon_cpu_pct,muon_rss_kb
# - avg/stddev: trimmed mean/stddev from calculate_stats (needs 3+ valid runs).
# - min/max: trimmed min/max from calculate_stats (outer extremes dropped).
# - muon_cpu_pct: mean Muon CPU% (1 decimal); empty for non-Muon cells.
# - muon_rss_kb: peak Muon RSS in kbytes; empty for non-Muon cells.
# - INVALID rows (<3 valid runs) keep the 10-field shape with zeroed stats:
#   category,name,INVALID,0.000,0.000,0.000,valid,dropped,,
finalize_cell() {
  local name="$1"
  local category="$2"
  local key="$category|$name"
  local safe_name="${name// /_}"
  local times_file="/tmp/muon_cell_${category}_${safe_name}.times"
  local dropped="${CELL_DROPPED[$key]:-0}"

  local times=()
  if [ -f "$times_file" ]; then
    mapfile -t times < "$times_file"
  fi
  local valid=${#times[@]}

  if [ "$valid" -lt 3 ]; then
    echo ">> INVALID: Only $valid clean runs (need 3+). <<"
    echo "$category,$name,INVALID,0.000,0.000,0.000,$valid,$dropped,," >> "$RESULTS_FILE"
    return
  fi

  local stats=($(calculate_stats "${times[@]}"))
  local avg=${stats[0]}
  local stddev=${stats[1]}
  local min=${stats[2]}
  local max=${stats[3]}

  local muon_cpu="" muon_rss=""
  if [ "${CELL_CPU_COUNT[$key]:-0}" -gt 0 ]; then
    muon_cpu=$(awk -v sum="${CELL_CPU_SUM[$key]}" -v n="${CELL_CPU_COUNT[$key]}" 'BEGIN { printf "%.1f", sum / n }')
  fi
  [ -n "${CELL_RSS_MAX[$key]:-}" ] && muon_rss="${CELL_RSS_MAX[$key]}"

  echo ">> Average for $name: ${avg}s (±${stddev}s) | $valid clean runs, $dropped dropped <<"
  echo "$category,$name,$avg,$stddev,$min,$max,$valid,$dropped,$muon_cpu,$muon_rss" >> "$RESULTS_FILE"
}

# Drives one category with interleaved rounds: warm every active cell once,
# then alternate cells round by round so thermal drift is spread across all
# tracers instead of biasing whichever ran last, then emit one CSV row per
# cell. Cell specs are '|'-delimited — name|prefix_cmd|bg_cmd|workload|category
# (no command field contains '|'; spaces are preserved).
run_category_rounds() {
  local -a cell_specs=("$@")
  local spec name prefix_cmd bg_cmd workload category
  local -a active_specs=()
  local category_label=""

  for spec in "${cell_specs[@]}"; do
    IFS='|' read -r name prefix_cmd bg_cmd workload category <<< "$spec"
    category_label="$category"
    if cell_active "$name"; then
      active_specs+=("$spec")
    elif [ "$MUON_ONLY" -eq 1 ]; then
      echo "  [muon-only] skipping $name"
    else
      echo "  [tracers-only] skipping $name"
    fi
  done

  [ "${#active_specs[@]}" -eq 0 ] && return 0

  # Warm every cell. A failed Muon/Baseline warmup aborts the session (the
  # core pipeline is broken, nothing measured afterwards would mean
  # anything). A failed strace/perf warmup only disables that comparator
  # cell — it still gets an INVALID row at finalize, and the session goes on.
  local -a round_specs=()
  for spec in "${active_specs[@]}"; do
    IFS='|' read -r name prefix_cmd bg_cmd workload category <<< "$spec"
    if warm_cell "$name" "$prefix_cmd" "$bg_cmd" "$workload" "$category"; then
      round_specs+=("$spec")
    elif [[ "$name" == "Muon" || "$name" == "Baseline" ]]; then
      echo ">> ABORT: warmup failed for core cell $name — setup is broken. <<" >&2
      exit 1
    else
      echo ">> CELL DISABLED: $name warmup failed — comparator unavailable, reporting INVALID. <<"
    fi
  done

  local r
  for r in $(seq 1 $ITERATIONS); do
    echo ""
    echo "Round $r/$ITERATIONS [$category_label]"
    for spec in "${round_specs[@]}"; do
      IFS='|' read -r name prefix_cmd bg_cmd workload category <<< "$spec"
      check_thermal
      timed_round "$name" "$prefix_cmd" "$bg_cmd" "$workload" "$category" "$r"
    done
  done

  for spec in "${active_specs[@]}"; do
    IFS='|' read -r name prefix_cmd bg_cmd workload category <<< "$spec"
    finalize_cell "$name" "$category"
  done
}

# =============================================================================
# SESSION GATE + CAPACITY SWEEP
# =============================================================================

# Functional child-tracking gate: one untimed Muon run whose workload spawns
# GATE_CHILDREN short-lived children. Regression class caught: Muon attaches
# and reports ready with non-zero events but stops following forked children,
# so the children's exec/exit events silently vanish while the run still looks
# healthy. Each child yields fork+exec+exit, so ~3K events are expected at
# K=500; requiring >= K is the conservative floor.
run_gate() {
  if [[ "$TRACERS_ONLY" -eq 1 ]]; then
    echo "GATE: skipping child-tracking smoke test (tracers-only mode — Muon is skipped)"
    return 0
  fi

  local gate_children=500
  [[ "$FAST_MODE" -eq 1 ]] && gate_children=100
  local gate_workload="for ((i=0; i<${gate_children}; i++)); do /bin/true; done"

  echo ""
  echo "========================================="
  echo " GATE: child-tracking (${gate_children} children)"
  echo "========================================="

  local gate_rc=0
  single_run "Gate" "" "$MUON_BIN attach -p $$ --headless" "$gate_workload" 0 "Gate" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    echo "ABORT: gate setup failed (rc=$gate_rc)" >&2
    exit 1
  fi

  local gate_events=""
  if [ -r /tmp/muon_lastevents.txt ]; then
    gate_events=$(sed -n 's/^MUON_EVENTS=//p' /tmp/muon_lastevents.txt | tail -n 1)
  fi
  if [[ "$gate_events" =~ ^[0-9]+$ ]] && [ "$gate_events" -ge "$gate_children" ]; then
    echo "GATE PASS: Muon observed $gate_events events from $gate_children spawned children"
  else
    echo "ABORT: GATE FAIL — expected >= $gate_children events from $gate_children spawned children, got ${gate_events:-none}" >&2
    exit 1
  fi
}

# --sweep capacity scan: for each openat level, one untimed prime plus three
# timed runs call single_run directly (the sweep keeps its own accounting and
# does not reuse timed_round/finalize). Wall time is taken only from rc 0 runs,
# event totals from /tmp/muon_lastevents.txt after every run; rc 3 counts as a
# drop and rc 1/2/4/5 as a failure.
run_sweep() {
  if [[ "$TRACERS_ONLY" -eq 1 ]]; then
    echo "SWEEP: skipping capacity scan — tracers-only mode runs no Muon."
    return 0
  fi

  local -a levels
  if [[ "$FAST_MODE" -eq 1 ]]; then
    levels=(10000 20000 50000)
  else
    levels=(50000 100000 200000 400000 800000)
  fi

  echo ""
  echo "================================================================="
  echo " SWEEP REPORT — Muon capacity scan (openat)"
  echo "================================================================="
  printf "%-10s %-10s %-10s %-12s %-7s %-8s\n" "Ops" "Avg(s)" "Events" "Events/s" "Drops" "Status"

  local sweep_best_rate=0 sweep_best_ops="" lvl r
  for lvl in "${levels[@]}"; do
    local sweep_bg="$MUON_BIN attach -p $$ --headless"
    local sweep_workload="stress-ng --open 4 --open-ops $lvl"

    # Failed setup is failed setup: abort the session like a failed warmup.
    local prime_rc=0
    single_run "Sweep $lvl" "" "$sweep_bg" "$sweep_workload" 0 "Sweep $lvl prime" || prime_rc=$?
    if [ "$prime_rc" -ne 0 ]; then
      echo ">> ABORT: sweep prime failed (rc=$prime_rc) for ops=$lvl — setup is broken. <<" >&2
      exit 1
    fi

    local -a sweep_times=()
    local -a sweep_events=()
    local drops=0 valid=0
    for r in 1 2 3; do
      local run_out="" run_rc=0
      run_out=$(single_run "Sweep $lvl" "" "$sweep_bg" "$sweep_workload" 1 "Sweep $lvl run $r") || run_rc=$?

      local ev=""
      if [ -r /tmp/muon_lastevents.txt ]; then
        ev=$(sed -n 's/^MUON_EVENTS=//p' /tmp/muon_lastevents.txt | tail -n 1)
      fi

      if [ "$run_rc" -eq 0 ]; then
        sweep_times+=("$run_out")
        valid=$((valid + 1))
        # Only timed or drop-marked runs contribute event counts; failed
        # runs (rc 1/2/4) carry no meaningful tally.
        [[ "$ev" =~ ^[0-9]+$ ]] && sweep_events+=("$ev")
      elif [ "$run_rc" -eq 3 ]; then
        drops=$((drops + 1))
        [[ "$ev" =~ ^[0-9]+$ ]] && sweep_events+=("$ev")
      fi
      echo "  Sweep $lvl run $r/3: rc=$run_rc events=${ev:-n/a}"
    done

    local avg_time="0.000" mean_events="0" ev_per_s="0" status="FAILED"
    if [ "${#sweep_times[@]}" -gt 0 ]; then
      avg_time=$(printf '%s\n' "${sweep_times[@]}" | awk '{s+=$1} END {printf "%.3f", s/NR}')
    fi
    if [ "${#sweep_events[@]}" -gt 0 ]; then
      mean_events=$(printf '%s\n' "${sweep_events[@]}" | awk '{s+=$1} END {printf "%.0f", s/NR}')
    fi
    if awk -v t="$avg_time" 'BEGIN { exit (t > 0) ? 0 : 1 }'; then
      ev_per_s=$(awk -v e="$mean_events" -v t="$avg_time" 'BEGIN { printf "%d", int(e / t) }')
    fi

    if [ "$drops" -gt 0 ]; then
      status="DROPS"
    elif [ "$valid" -eq 3 ]; then
      status="CLEAN"
    fi

    echo "sweep: ops=$lvl avg=$avg_time events=$mean_events ev_per_s=$ev_per_s drops=$drops status=$status" >> "$RESULTS_FILE"
    printf "%-10s %-10s %-10s %-12s %-7s %-8s\n" "$lvl" "$avg_time" "$mean_events" "$ev_per_s" "$drops" "$status"

    if [ "$status" = "CLEAN" ] && [ "$ev_per_s" -ge "$sweep_best_rate" ]; then
      sweep_best_rate="$ev_per_s"
      sweep_best_ops="$lvl"
    fi
  done

  if [ -n "$sweep_best_ops" ]; then
    echo "Max drop-free rate: ~$sweep_best_rate events/s at $sweep_best_ops openat ops"
  else
    echo "Max drop-free rate: none — Muon dropped at every level"
  fi
}

# =============================================================================
# WORKLOADS
# =============================================================================

# Run the child-tracking gate once, before any category measures anything.
run_gate

# --- 1. EXEC-heavy ---
EXEC_WORKLOAD="sudo -u \$SUDO_USER stress-ng --exec 4 --exec-ops $EXEC_OPS"
echo ""
echo "========================================="
echo " CATEGORY 1: exec-heavy"
echo "========================================="
CELL_SPECS=(
  "Baseline|||$EXEC_WORKLOAD|exec"
  "strace|strace -f -e trace=execve,exit -o /dev/null||$EXEC_WORKLOAD|exec"
  "perf trace|perf trace -e execve,exit -o /dev/null --||$EXEC_WORKLOAD|exec"
  "Muon||$MUON_BIN attach -p $$ --headless|$EXEC_WORKLOAD|exec"
)
run_category_rounds "${CELL_SPECS[@]}"

# --- 2. OPEN-heavy ---
OPEN_WORKLOAD="stress-ng --open 4 --open-ops $OPEN_OPS"
echo ""
echo "========================================="
echo " CATEGORY 2: openat-heavy"
echo "========================================="
CELL_SPECS=(
  "Baseline|||$OPEN_WORKLOAD|open"
  "strace|strace -f -e trace=openat -o /dev/null||$OPEN_WORKLOAD|open"
  "perf trace|perf trace -e openat -o /dev/null --||$OPEN_WORKLOAD|open"
  "Muon||$MUON_BIN attach -p $$ --headless|$OPEN_WORKLOAD|open"
)
run_category_rounds "${CELL_SPECS[@]}"

# --- 3. MMAP-heavy ---
MMAP_WORKLOAD="stress-ng --mmap 4 --mmap-mprotect --mmap-bytes 4K --mmap-ops $MMAP_OPS"
echo ""
echo "========================================="
echo " CATEGORY 3: mmap-heavy"
echo "========================================="
CELL_SPECS=(
  "Baseline|||$MMAP_WORKLOAD|mmap"
  "strace|strace -f -e trace=mmap,brk,munmap -o /dev/null||$MMAP_WORKLOAD|mmap"
  "perf trace|perf trace -e mmap,brk,munmap -o /dev/null --||$MMAP_WORKLOAD|mmap"
  "Muon||$MUON_BIN attach -p $$ --headless|$MMAP_WORKLOAD|mmap"
)
run_category_rounds "${CELL_SPECS[@]}"

# --- 4. MIXED (Regression) ---
# MIXED_WORKLOAD="sudo -u \$SUDO_USER stress-ng --exec 2 --exec-ops $MIXED_EXEC_OPS --mmap 2 --mmap-mprotect --mmap-ops $MIXED_MMAP_OPS --open 2 --open-ops $MIXED_OPEN_OPS"
# echo ""
# echo "========================================="
# echo " CATEGORY 4: mixed (regression test)"
# echo "========================================="
# CELL_SPECS=(
#   "Baseline|||$MIXED_WORKLOAD|mixed"
#   "strace|strace -f -e trace=execve,exit,openat,mmap,brk -o /dev/null||$MIXED_WORKLOAD|mixed"
#   "perf trace|perf trace -e execve,exit,openat,mmap,brk -o /dev/null --||$MIXED_WORKLOAD|mixed"
#   "Muon||$MUON_BIN attach -p $$ --headless|$MIXED_WORKLOAD|mixed"
# )
# run_category_rounds "${CELL_SPECS[@]}"

# --- 4. go-build ---
# `find ... -exec touch` only refreshes mtimes of Go sources (git-neutral, no
# content change); build output goes to /tmp so the repo stays clean. The Go
# toolchain is checked once here, not on every run.
if ! command -v go >/dev/null 2>&1; then
  echo "ABORT: go toolchain not found in PATH — required for the go-build category." >&2
  exit 1
fi
GOBUILD_WORKLOAD="cd \"\$SCRIPT_DIR\" && find . -name '*.go' -exec touch {} + && go build -o /tmp/muon_build_test ."
echo ""
echo "========================================="
echo " CATEGORY 4: go-build"
echo "========================================="
CELL_SPECS=(
  "Baseline|||$GOBUILD_WORKLOAD|gobuild"
  "strace|strace -f -e trace=execve,exit,openat,mmap,brk,munmap -o /dev/null||$GOBUILD_WORKLOAD|gobuild"
  "perf trace|perf trace -e execve,exit,openat,mmap,brk,munmap -o /dev/null --||$GOBUILD_WORKLOAD|gobuild"
  "Muon||$MUON_BIN attach -p $$ --headless|$GOBUILD_WORKLOAD|gobuild"
)
run_category_rounds "${CELL_SPECS[@]}"

# --- 5. kernel-compile (--publication only) ---
echo ""
echo "========================================="
echo " CATEGORY 5: kernel-compile"
echo "========================================="
if [ "$PUBLICATION" -eq 1 ]; then
  KERNEL_SRC="${KERNEL_SRC:-$HOME/linux}"
  if [ ! -f "$KERNEL_SRC/Makefile" ]; then
    echo "ABORT: no kernel tree at $KERNEL_SRC (Makefile missing)." >&2
    echo "Set KERNEL_SRC to a configured kernel tree, then re-run." >&2
    exit 1
  fi
  export KERNEL_SRC

  # One untimed defconfig so every timed build starts from a known config.
  if ! make -C "$KERNEL_SRC" defconfig >/dev/null 2>&1; then
    echo "ABORT: make -C $KERNEL_SRC defconfig failed." >&2
    exit 1
  fi

  # Each kernel build is ~10 min, so publication uses 3 timed rounds and a
  # single warmup; the suite defaults are restored right after.
  SAVED_ITERATIONS="$ITERATIONS"
  SAVED_WARMUP="$WARMUP"
  ITERATIONS=3
  WARMUP=1

  # -j4 matches the 4 cores pinned for workloads (WORKLOAD_CORES).
  KBUILD_WORKLOAD="make -C \"\$KERNEL_SRC\" clean >/dev/null && make -C \"\$KERNEL_SRC\" -j4"
  CELL_SPECS=(
    "Baseline|||$KBUILD_WORKLOAD|kbuild"
    "strace|strace -f -e trace=execve,exit,openat,mmap,brk,munmap -o /dev/null||$KBUILD_WORKLOAD|kbuild"
    "perf trace|perf trace -e execve,exit,openat,mmap,brk,munmap -o /dev/null --||$KBUILD_WORKLOAD|kbuild"
    "Muon||$MUON_BIN attach -p $$ --headless|$KBUILD_WORKLOAD|kbuild"
  )
  run_category_rounds "${CELL_SPECS[@]}"

  ITERATIONS="$SAVED_ITERATIONS"
  WARMUP="$SAVED_WARMUP"
else
  echo "  [publication-skip] kernel-compile requires --publication"
fi

# --- Capacity sweep (--sweep only) ---
if [[ "$SWEEP" -eq 1 ]]; then
  run_sweep
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "================================================================="
echo " RESULTS SUMMARY"
echo "================================================================="
echo ""
printf "%-12s %-20s %-10s %-11s %-10s %-10s %-10s %-9s %-10s %-11s\n" "Category" "Tracer" "Avg(s)" "StdDev(s)" "Min(s)" "Max(s)" "CleanRuns" "Dropped" "MuonCPU%" "MuonRSS(KB)"
printf "%-12s %-20s %-10s %-11s %-10s %-10s %-10s %-9s %-10s %-11s\n" "--------" "------" "------" "---------" "------" "------" "---------" "-------" "--------" "-----------"

while IFS=',' read -r category name avg stddev min max valid dropped muon_cpu muon_rss; do
  [[ "$category" == coremap:* || "$category" == sweep:* ]] && continue
  [ -z "$muon_cpu" ] && muon_cpu="-"
  [ -z "$muon_rss" ] && muon_rss="-"
  printf "%-12s %-20s %-10s %-11s %-10s %-10s %-10s %-9s %-10s %-11s\n" "$category" "$name" "$avg" "±$stddev" "$min" "$max" "$valid" "$dropped" "$muon_cpu" "$muon_rss"
done < "$RESULTS_FILE"

if [[ "$MUON_ONLY" -eq 1 || "$TRACERS_ONLY" -eq 1 ]]; then
  echo "Derived overhead needs a full run with a Baseline cell."
else
  echo ""
  echo "================================================================="
  echo " OVERHEAD vs BASELINE"
  echo "================================================================="
  printf "%-12s %-20s %-12s %-10s %-13s %-10s\n" "Category" "Tracer" "Overhead%" "±Err" "PerEvent(ns)" "Verdict"
  printf "%-12s %-20s %-12s %-10s %-13s %-10s\n" "--------" "------" "---------" "-----" "------------" "-------"
  awk -F',' -v exec_ops="$EXEC_OPS" -v open_ops="$OPEN_OPS" -v mmap_ops="$MMAP_OPS" '
    FNR == NR {
      if ($1 ~ /^coremap:/ || $1 ~ /^sweep:/) next
      if ($2 == "Baseline" && $3 != "INVALID") {
        base_avg[$1] = $3 + 0
        base_sd[$1] = $4 + 0
        have_base[$1] = 1
      }
      next
    }
    $1 ~ /^coremap:/ || $1 ~ /^sweep:/ { next }
    $2 == "Baseline" { next }
    $3 == "INVALID" { next }
    {
      cat = $1
      T = $3 + 0
      St = $4 + 0
      if (!have_base[cat] || base_avg[cat] == 0) {
        printf "%-12s %-20s %-12s %-10s %-13s %-10s\n", cat, $2, "n/a", "n/a", "n/a", "n/a"
        next
      }
      B = base_avg[cat]
      Sb = base_sd[cat]
      oh = (T - B) / B * 100
      err = 100 * sqrt((St / B) ^ 2 + (T * Sb / (B * B)) ^ 2)
      gap = T - B
      if (gap < 0) gap = -gap
      verdict = (gap < 2 * sqrt(St * St + Sb * Sb)) ? "NOISE" : "REAL"
      if (cat == "exec") ops = exec_ops
      else if (cat == "open") ops = open_ops
      else if (cat == "mmap") ops = mmap_ops
      else ops = 0
      if (ops > 0) per_event = sprintf("%.0f", (T - B) * 1e9 / ops)
      else per_event = "-"
      printf "%-12s %-20s %-12s %-10s %-13s %-10s\n", cat, $2, sprintf("%.1f%%", oh), sprintf("±%.1f%%", err), per_event, verdict
    }
  ' "$RESULTS_FILE" "$RESULTS_FILE"
fi

echo ""
if [[ "$MUON_ONLY" -eq 1 ]]; then
  echo "Muon-only mode: no baseline in this session."
  echo "overhead% needs a full run: sudo ./benchmark_muon.sh [--fast]"
elif [[ "$TRACERS_ONLY" -eq 1 ]]; then
  echo "Tracers-only mode: no baseline in this session."
  echo "overhead% needs a full run: sudo ./benchmark_muon.sh [--fast]"
else
  echo "Overhead calculation:"
  echo "  overhead% = ((tracer_avg - baseline_avg) / baseline_avg) * 100"
  echo "  ±Err = 100 * sqrt((tracer_stddev / baseline_avg)^2 + (tracer_avg * baseline_stddev / baseline_avg^2)^2)"
  echo "  Verdict: NOISE when |tracer_avg - baseline_avg| < 2 * sqrt(tracer_stddev^2 + baseline_stddev^2), else REAL"
fi
echo ""
