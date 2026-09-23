#!/bin/bash
# =============================================================================
# Muon Benchmark Suite - Fair, Reproducible & Mathematically Sound
# =============================================================================

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./benchmark_muon.sh"
  exit 1
fi

export LC_ALL=C
export LC_NUMERIC=C

MUON_BIN="./muon"
RESULTS_FILE="/tmp/muon_bench_results.txt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# Shared helpers (require_tool, safe_str, tally, stop_muon).
LIB_SH="$SCRIPT_DIR/bench/lib.sh"
[ -f "$LIB_SH" ] || { echo "ABORT: $LIB_SH missing." >&2; exit 1; }
# shellcheck disable=SC1091
. "$LIB_SH"

# Session stamp, computed once up front so both the normal archive and the
# abort-path preservation in session_cleanup use the same directory name.
CPU_TAG=$(lscpu 2>/dev/null | sed -n 's/^[[:space:]]*Model name:[[:space:]]*//p' | head -n 1 \
  | sed -E 's/\((R|TM|r|tm)\)//g; s/\b(Intel|AMD|Core|CPU|Processor|Genuine)\b//gI' \
  | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
[ -n "$CPU_TAG" ] || CPU_TAG="unknown"
STAMP="$(date +%Y%m%d-%H%M%S)-$(uname -r)-${CPU_TAG}"
ARCHIVED=0

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
REGRESS=off
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    --muon-only) MUON_ONLY=1 ;;
    --tracers-only) TRACERS_ONLY=1 ;;
    --publication) PUBLICATION=1 ;;
    --sweep) SWEEP=1 ;;
    --regress) REGRESS=fail ;;
    --regress=*)
      REGRESS="${arg#--regress=}"
      if [[ "$REGRESS" != "warn" && "$REGRESS" != "fail" ]]; then
        echo "Invalid --regress value: '$REGRESS' (accepted: warn, fail)" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown option: $arg (supported: --fast, --muon-only, --tracers-only, --publication, --sweep, --regress[=warn|fail])"
      exit 1
      ;;
  esac
done

if [[ "$FAST_MODE" -eq 1 ]]; then
    ITERATIONS=5
    EXEC_OPS=1000
    OPEN_OPS=100000
    MMAP_OPS=1000
    BRK_OPS=200000
    CONN_OPS=50000
    PTHREAD_OPS=5000

    WARMUP=1

    echo "============================================="
    echo " Muon Benchmark Suite [FAST DEV MODE]"
    echo "============================================="
else
    ITERATIONS=10
    EXEC_OPS=10000
    OPEN_OPS=300000
    MMAP_OPS=15000
    BRK_OPS=1000000
    CONN_OPS=300000
    PTHREAD_OPS=20000

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

if [[ "$REGRESS" != "off" ]]; then
  echo " REGRESS MODE ($REGRESS) — comparing against bench/baseline.json"
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

# Clear stale per-run artifacts so an earlier session can never bleed in.
LIVE_PGID_FILE="/tmp/muon_live.pgid"
rm -f /tmp/muon_*.log /tmp/muon_res_*.txt /tmp/muon_workload_err_*.txt \
  /tmp/muon_cell_*.times /tmp/muon_lastres.txt /tmp/muon_time.txt \
  /tmp/muon_lastevents.txt "$LIVE_PGID_FILE"

# One session at a time (shared governors, cores, results file, /tmp
# channels). The fd stays open, so the lock releases on exit.
exec 200>/tmp/muon_bench.lock
if ! flock -n 200 2>/dev/null; then
  echo "ABORT: another benchmark session holds /tmp/muon_bench.lock." >&2
  echo "Concurrent sessions would corrupt each other's results — wait for it to finish." >&2
  exit 1
fi

# Fail fast on missing tools, before touching system state. Lists are
# mode-aware (comparators need --muon-only off, make needs --publication).
[ -x /usr/bin/time ] || { echo "ABORT: /usr/bin/time missing (need GNU time for resource accounting)." >&2; exit 1; }
require_tool "setsid taskset awk sort grep flock id python3 go"
require_tool "stress-ng"
if [[ "$MUON_ONLY" -eq 0 ]]; then
  require_tool "strace perf"
fi
if [[ "$PUBLICATION" -eq 1 ]]; then
  require_tool "make"
fi
if command -v pkill >/dev/null 2>&1; then
  PKILL_OK=1
else
  PKILL_OK=0
  echo "WARNING: pkill not found — tracer shutdown falls back to group kill and tracer CPU/RSS figures will be missing." >&2
fi

# The exec workload drops privileges via sudo (overridable via
# MUON_BENCH_USER); validate the account now, not as a cryptic failure later.
SUDO_USER="${SUDO_USER:-${MUON_BENCH_USER:-}}"
if [ -z "$SUDO_USER" ]; then
  echo "ABORT: no unprivileged account to run the exec workload as." >&2
  echo "Run via 'sudo ./benchmark_muon.sh ...' from your user account, or set MUON_BENCH_USER." >&2
  exit 1
fi
if ! id -u "$SUDO_USER" >/dev/null 2>&1; then
  echo "ABORT: account '$SUDO_USER' does not exist (needed for the exec workload)." >&2
  exit 1
fi
export SUDO_USER

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
  # Restore only saved entries; never invent a governor for unknown CPUs.
  for gov_file in "${!SAVED_GOVERNORS[@]}"; do
    echo "${SAVED_GOVERNORS["$gov_file"]}" > "$gov_file" 2>/dev/null
  done
}

# Session cleanup on every exit path: restores governors, reaps a possibly
# interrupted tracer pipeline, preserves partial results on abnormal exit.
session_cleanup() {
  local rc=$?
  restore_governors
  if [ -f "$LIVE_PGID_FILE" ]; then
    local pgid
    pgid=$(cat "$LIVE_PGID_FILE" 2>/dev/null)
    if [[ "$pgid" =~ ^[0-9]+$ ]] && kill -0 "-$pgid" 2>/dev/null; then
      kill -SIGKILL -- "-$pgid" 2>/dev/null
    fi
    rm -f "$LIVE_PGID_FILE"
  fi
  if [ "$rc" -ne 0 ] && [ "${ARCHIVED:-0}" -eq 0 ] && [ -f "$RESULTS_FILE" ] \
      && grep -qE '^[^,]+,[^,]+,' "$RESULTS_FILE" 2>/dev/null; then
    local ab_dest="$SCRIPT_DIR/bench/results/aborted-$STAMP"
    if mkdir -p "$ab_dest" 2>/dev/null; then
      cp "$RESULTS_FILE" "$ab_dest/results.csv" 2>/dev/null || echo "WARNING: could not preserve partial results." >&2
      [ -f "$ENV_FILE" ] && cp "$ENV_FILE" "$ab_dest/env.txt" 2>/dev/null
      echo "Partial results preserved in bench/results/aborted-$STAMP"
    fi
  fi
  exit "$rc"
}
trap session_cleanup EXIT
trap 'exit 143' INT TERM

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
unverified=0
for idx in "${!WORKLOAD_FREQS[@]}"; do
  if [ "${WORKLOAD_FREQS[$idx]}" = "unknown" ]; then
    unverified=1
  elif [ "${WORKLOAD_FREQS[$idx]}" != "${WORKLOAD_FREQS[0]}" ] && [ "${WORKLOAD_FREQS[0]}" != "unknown" ]; then
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

if [ "$unverified" -eq 1 ]; then
  # No cpufreq data (VMs, some ARM) — homogeneity cannot be verified, so the
  # numbers are recorded as-is instead of aborting the session.
  echo "WARNING: could not read frequencies for all workload cores — homogeneity unverified, results carry that caveat."
  WORKLOAD_FREQS[0]="unknown"
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
    gov_now=$(cat "$gov_file" 2>/dev/null)
    gov_was="${SAVED_GOVERNORS["$gov_file"]:-unsaved}"
    echo "governor $(basename "$(dirname "$(dirname "$gov_file")")"): now=$gov_now was=$gov_was"
    if [ "$gov_now" != "performance" ]; then
      echo "WARNING: governor lock to 'performance' did not take effect on $(basename "$(dirname "$(dirname "$gov_file")")") — timings suspect."
    fi
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

# Abort when a CPU thermal zone is above 95°C so throttled numbers are never
# recorded. Prefers CPU/package/acpi zones; a GPU or NVMe sensor must not
# veto a CPU run, but when no zone is identifiable all readable zones count.
check_thermal() {
  local max_temp=0 zone temp ztype zd
  local -a cpu_zones=()
  local -a all_zones=()
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$zone" ] || continue
    temp=$(cat "$zone" 2>/dev/null)
    [[ "$temp" =~ ^[0-9]+$ ]] || continue
    all_zones+=("$temp")
    zd=$(dirname "$zone")
    ztype=$(cat "$zd/type" 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$ztype" in
      *cpu*|*pkg*|*acpi*|*soc*|*core*) cpu_zones+=("$temp") ;;
    esac
  done

  local -a use_zones=("${all_zones[@]}")
  if [ "${#cpu_zones[@]}" -gt 0 ]; then
    use_zones=("${cpu_zones[@]}")
  fi
  for temp in ${use_zones[@]+"${use_zones[@]}"}; do
    if [ "$temp" -gt "$max_temp" ]; then
      max_temp="$temp"
    fi
  done

  if [ "$max_temp" -gt 95000 ]; then
    echo "ABORT: CPU thermal zone at $((max_temp / 1000))°C (>95°C) — refusing to record throttled results." >&2
    exit 1
  fi
}

check_power_supply

# =============================================================================
# STATS HELPER
# =============================================================================

# Trimmed mean with sample standard deviation. The outer min/max are dropped
# only when count>=4 (with 3 runs there is nothing safe to trim — trimming
# would collapse stddev/min/max onto the median). sd uses n-1 (sample): the
# runs are a sample of the machine's behavior, so population variance would
# systematically understate run-to-run variability. Emits: mean stddev min max.
calculate_stats() {
  local values=("$@")
  local count=${#values[@]}

  if [ "$count" -lt 3 ]; then
    echo "0.000 0.000 0.000 0.000"
    return 1
  fi

  local sorted=($(printf '%s\n' "${values[@]}" | sort -n))
  local trimmed
  if [ "$count" -ge 4 ]; then
    trimmed=("${sorted[@]:1:$((count - 2))}")
  else
    trimmed=("${sorted[@]}")
  fi

  printf '%s\n' "${trimmed[@]}" | awk '{
    sum += $1;
    sumsq += ($1 * $1);
    n++;
    if (n == 1 || $1 < tmin) tmin = $1;
    if (n == 1 || $1 > tmax) tmax = $1;
  } END {
    if (n > 0) {
      mean = sum / n;
      var_num = sumsq - sum * sum / n;
      if (var_num < 0) var_num = 0;
      sd = (n > 1) ? sqrt(var_num / (n - 1)) : 0;
      printf "%.3f %.3f %.3f %.3f", mean, sd, tmin, tmax;
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

# =============================================================================
# SINGLE RUN HELPER
# =============================================================================

# One full iteration: drop caches, start Muon (if any), wait for readiness,
# run the workload, stop Muon. Timed wall time goes to stdout, diagnostics
# to stderr. Returns 0 clean, 1 not-ready, 2 bad timing, 3 ring-full,
# 4 zero events, 5 workload failed. Muon runs under /usr/bin/time -v;
# CPU%/RSS publish via /tmp/muon_lastres.txt (subshell-safe file channel).
single_run() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local timed="$5"
  local tag="$6"
  local safe_name="$(safe_str "$name")"
  local safe_tag="$(safe_str "$tag")"

  sync
  echo 3 > /proc/sys/vm/drop_caches
  sleep 0.5

  local muon_pid=""
  local muon_log="/tmp/muon_${safe_tag}.log"
  local muon_res="/tmp/muon_res_${safe_tag}.txt"
  if [ -n "$bg_cmd" ]; then
    rm -f "$muon_res"
    # setsid gives the pipeline (taskset/time/muon) its own group so teardown
    # signals ALL of it; killing just $! orphans a still-tracing Muon.
    # The PGID file lets the EXIT trap reap it if a signal lands mid-run.
    setsid taskset -c "$MUON_CORE" /usr/bin/time -v -o "$muon_res" $bg_cmd > "$muon_log" 2>&1 &
    muon_pid=$!
    echo "$muon_pid" > "$LIVE_PGID_FILE"
  fi

  # Poll readiness up to 10s: one slow attach must not abort the session.
  if [ -n "$muon_pid" ]; then
    local ready=0
    local wready
    for ((wready=0; wready<10; wready++)); do
      if ! kill -0 "$muon_pid" 2>/dev/null; then
        break
      fi
      if grep -q "Muon ready" "$muon_log" 2>/dev/null; then
        ready=1
        break
      fi
      sleep 1
    done
    if [ "$ready" -eq 0 ]; then
      if ! kill -0 "$muon_pid" 2>/dev/null; then
        echo "  $tag: FATAL — Muon exited before the run started:" >&2
      else
        echo "  $tag: FATAL — Muon never reported ready (10s):" >&2
      fi
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
  # Workload stdio joins the per-run file (never this function's stdout,
  # which feeds the $(...) capture); the file keeps --metrics-brief actuals.
  local workload_rc=0
  if [ -n "$prefix_cmd" ]; then
    /usr/bin/time -f "%e" -o /tmp/muon_time.txt \
      taskset -c "$WORKLOAD_CORES" $prefix_cmd bash -c "$workload" \
      >>"$workload_err" 2>&1
    workload_rc=$?
  else
    /usr/bin/time -f "%e" -o /tmp/muon_time.txt \
      taskset -c "$WORKLOAD_CORES" bash -c "$workload" \
      >>"$workload_err" 2>&1
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
    # Last EVENTS tally is authoritative: total = accepted events (parsed
    # minus userspace drops, reported separately). Missing/zero = observed
    # nothing. Totals publish via files (callers run in a subshell).
    # Drop counts ride in lastres.txt so the sweep sees drops even when
    # the rc reflects a different failure.
    local last_events
    last_events=$(grep "EVENTS:" "$muon_log" 2>/dev/null | tail -n 1)
    if [[ "$last_events" =~ total=([0-9]+) ]]; then
      printf 'MUON_EVENTS=%s\n' "${BASH_REMATCH[1]}" > /tmp/muon_lastevents.txt
      [ "${BASH_REMATCH[1]}" -gt 0 ] || zero_events=1
    else
      printf 'MUON_EVENTS=\n' > /tmp/muon_lastevents.txt
      zero_events=1
    fi
    if [[ "$last_events" =~ kernel_drops=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
      printf 'MUON_DROPS=1\n' >> /tmp/muon_lastres.txt
    elif [[ "$last_events" =~ userspace_drops=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -gt 0 ]; then
      printf 'MUON_DROPS=1\n' >> /tmp/muon_lastres.txt
    else
      printf 'MUON_DROPS=0\n' >> /tmp/muon_lastres.txt
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

# Untimed warmup: timing discarded, failure reported (caller aborts or
# disables), times file truncated against earlier sessions.
warm_cell() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local category="$5"
  local safe_name="$(safe_str "$name")"
  local times_file="/tmp/muon_cell_${category}_${safe_name}.times"

  : > "$times_file"

  echo ""
  echo "--- $name ---"

  local w=0 warm_rc=0
  for ((w = 1; w <= WARMUP; w++)); do
    check_thermal
    warm_rc=0
    single_run "$name" "$prefix_cmd" "$bg_cmd" "$workload" 0 "Warmup $w" || warm_rc=$?
    if [ "$warm_rc" -ne 0 ]; then
      echo ">> CELL FAILED: warmup $w/$WARMUP failed (rc=$warm_rc) for $name. <<" >&2
      return $warm_rc
    fi
    echo "  Warmup $w/$WARMUP: complete (timing discarded)"
  done
}

# One timed round: valid times append to the cell file, failures bump its
# dropped counter, Muon CPU/RSS fold into accumulators.
timed_round() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local category="$5"
  local round="$6"
  local key="$category|$name"
  local safe_name="$(safe_str "$name")"
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
    muon_cpu=$(tally /tmp/muon_lastres.txt MUON_CPU)
    muon_rss=$(tally /tmp/muon_lastres.txt MUON_RSS)
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
# - avg/stddev: trimmed mean and sample (n-1) stddev from calculate_stats
#   (needs 3+ valid runs; the outer pair is trimmed only with 4+ runs).
# - min/max: of the trimmed set when trimmed, raw extremes otherwise.
# - muon_cpu_pct: mean Muon CPU% (1 decimal); empty for prefix-wrapped cells
#   (strace/perf run in the foreground under plain `time`, so no resource
#   figures exist for them) and when the report was unavailable.
# - muon_rss_kb: peak Muon RSS in kbytes; empty under the same conditions.
# - INVALID rows (<3 valid runs) keep the 10-field shape with zeroed stats:
#   category,name,INVALID,0.000,0.000,0.000,valid,dropped,,
finalize_cell() {
  local name="$1"
  local category="$2"
  local key="$category|$name"
  local safe_name="$(safe_str "$name")"
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

# Interleaved rounds per category: warm all cells, alternate them each round
# (thermal drift hits everyone equally), emit one CSV row per cell.
# Specs are '|' delimited (no command field contains '|').
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

# Child-tracking gate: spawn K children under Muon, require ≥K events.
# Catches Muon attaching fine but going blind to forked children.
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

  check_thermal
  local gate_rc=0
  single_run "Gate" "" "$MUON_BIN attach -p $$ --headless" "$gate_workload" 0 "Gate" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    echo "ABORT: gate setup failed (rc=$gate_rc)" >&2
    exit 1
  fi

  local gate_events=""
  gate_events=$(tally /tmp/muon_lastevents.txt MUON_EVENTS)
  if [[ "$gate_events" =~ ^[0-9]+$ ]] && [ "$gate_events" -ge "$gate_children" ]; then
    echo "GATE PASS: Muon observed $gate_events events from $gate_children spawned children"
  else
    echo "ABORT: GATE FAIL — expected >= $gate_children events from $gate_children spawned children, got ${gate_events:-none}" >&2
    exit 1
  fi
}

# Sweep: prime + 3 timed runs per brk-worker level (own accounting, not
# timed_round/finalize). Levels scale WORKERS at fixed ops — only concurrent
# rate moves events/sec. rc 3 = drop, rc 1/2/4/5 = failure.
run_sweep() {
  if [[ "$TRACERS_ONLY" -eq 1 ]]; then
    echo "SWEEP: skipping capacity scan — tracers-only mode runs no Muon."
    return 0
  fi

  local -a levels
  local sweep_ops
  if [[ "$FAST_MODE" -eq 1 ]]; then
    levels=(1 2 4)
    sweep_ops=200000
  else
    levels=(2 4 8 12)
    sweep_ops=1000000
  fi

  echo ""
  echo "================================================================="
  echo " SWEEP REPORT — Muon capacity scan (brk workers)"
  echo "================================================================="
  printf "%-10s %-10s %-10s %-10s %-12s %-7s %-8s\n" "Workers" "Ops" "Avg(s)" "Events" "Events/s" "Drops" "Status"

  local sweep_best_rate=0 sweep_best_workers="" lvl r
  for lvl in "${levels[@]}"; do
    check_thermal
    local sweep_bg="$MUON_BIN attach -p $$ --headless"
    local sweep_workload="stress-ng --brk $lvl --brk-ops $sweep_ops --metrics-brief"

    # Failed setup is failed setup: abort the session like a failed warmup.
    local prime_rc=0
    single_run "Sweep brk$lvl" "" "$sweep_bg" "$sweep_workload" 0 "Sweep brk$lvl prime" || prime_rc=$?
    if [ "$prime_rc" -ne 0 ]; then
      echo ">> ABORT: sweep prime failed (rc=$prime_rc) for workers=$lvl — setup is broken. <<" >&2
      exit 1
    fi

    local -a sweep_times=()
    local -a sweep_events=()
    local drops=0 valid=0
    for r in 1 2 3; do
      local run_out="" run_rc=0
      run_out=$(single_run "Sweep brk$lvl" "" "$sweep_bg" "$sweep_workload" 1 "Sweep brk$lvl run $r") || run_rc=$?

      local ev="" dropped=""
      ev=$(tally /tmp/muon_lastevents.txt MUON_EVENTS)
      dropped=$(tally /tmp/muon_lastres.txt MUON_DROPS)

      if [ "$run_rc" -eq 0 ]; then
        sweep_times+=("$run_out")
        valid=$((valid + 1))
        # Only timed or drop-marked runs contribute event counts; failed
        # runs (rc 1/2/4/5) carry no meaningful tally. A run can be both
        # timed AND drop-marked (drops with a valid wall time).
        [[ "$ev" =~ ^[0-9]+$ ]] && sweep_events+=("$ev")
        [[ "$dropped" == "1" ]] && drops=$((drops + 1))
      elif [ "$run_rc" -eq 3 ]; then
        drops=$((drops + 1))
        [[ "$ev" =~ ^[0-9]+$ ]] && sweep_events+=("$ev")
      fi
      echo "  Sweep brk$lvl run $r/3: rc=$run_rc events=${ev:-n/a}"
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

    # CLEAN needs a full house with no drops; DROPS means backpressure was
    # observed on an otherwise measured level; anything else is FAILED.
    if [ "$valid" -eq 3 ] && [ "$drops" -eq 0 ]; then
      status="CLEAN"
    elif [ "$drops" -gt 0 ] && [ "$valid" -gt 0 ]; then
      status="DROPS"
      any_drops=1
    fi

    echo "sweep: ops=$sweep_ops workers=$lvl avg=$avg_time events=$mean_events ev_per_s=$ev_per_s drops=$drops status=$status" >> "$RESULTS_FILE"
    printf "%-10s %-10s %-10s %-10s %-12s %-7s %-8s\n" "$lvl" "$sweep_ops" "$avg_time" "$mean_events" "$ev_per_s" "$drops" "$status"

    if [ "$status" = "CLEAN" ] && [ "$ev_per_s" -ge "$sweep_best_rate" ]; then
      sweep_best_rate="$ev_per_s"
      sweep_best_workers="$lvl"
    fi
  done

  if [ "${any_drops:-0}" -eq 1 ]; then
    echo "note: ev/s on DROPS rows is a lower bound — dropped events are uncounted by design."
  fi

  if [ -n "$sweep_best_workers" ]; then
    echo "Max drop-free rate: ~$sweep_best_rate events/s at $sweep_best_workers brk workers ($sweep_ops ops)"
  else
    echo "Max drop-free rate: none — Muon dropped at every level"
  fi
}

# =============================================================================
# WORKLOADS
# =============================================================================

# Run the child-tracking gate once, before any category measures anything.
run_gate

# Map-limit probe: hold more live children than tracked_pids entries (16384),
# then reap them (exit storm). Muon-only, untimed, drops tolerated+reported.
run_maptest() {
  if [[ "$TRACERS_ONLY" -eq 1 ]]; then
    echo "MAPTEST: skipping (tracers-only mode — Muon is skipped)"
    return 0
  fi

  local map_children=18000 map_need_kb=6291456 map_need_proc=25000 map_floor=25000
  if [[ "$FAST_MODE" -eq 1 ]]; then
    map_children=3000; map_need_kb=2097152; map_need_proc=5000; map_floor=4000
  fi

  local mem_kb
  mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null)
  if [[ ! "$mem_kb" =~ ^[0-9]+$ ]] || [ "$mem_kb" -lt "$map_need_kb" ]; then
    echo "MAPTEST: skipping — need ${map_need_kb}kB available RAM for $map_children concurrent children (have ${mem_kb:-unknown}kB)."
    return 0
  fi
  local max_proc
  max_proc=$(ulimit -u)
  if [[ ! "$max_proc" =~ ^[0-9]+$ ]] || [ "$max_proc" -lt "$map_need_proc" ]; then
    echo "MAPTEST: skipping — need nproc >= $map_need_proc for $map_children concurrent children (have ${max_proc:-unknown})."
    return 0
  fi

  echo ""
  echo "========================================="
  echo " MAPTEST: $map_children concurrent children (map holds 16384)"
  echo "========================================="

  check_thermal
  local map_workload="for i in \$(seq 1 $map_children); do sleep 300 & done; jobs -p | xargs -r kill 2>/dev/null; wait; true"
  local map_rc=0
  single_run "Maptest" "" "$MUON_BIN attach -p $$ --headless" "$map_workload" 0 "Maptest" || map_rc=$?
  if [ "$map_rc" -ne 0 ] && [ "$map_rc" -ne 3 ]; then
    echo "ABORT: maptest setup failed (rc=$map_rc)" >&2
    exit 1
  fi

  local map_events="" map_drops=""
  map_events=$(tally /tmp/muon_lastevents.txt MUON_EVENTS)
  map_drops=$(tally /tmp/muon_lastres.txt MUON_DROPS)
  if [[ "$map_events" =~ ^[0-9]+$ ]] && [ "$map_events" -ge "$map_floor" ]; then
    echo "MAPTEST PASS: Muon observed $map_events events across $map_children spawned-and-reaped children (drops seen: ${map_drops:-0})"
  else
    echo "ABORT: MAPTEST FAIL — expected >= $map_floor events, got ${map_events:-none}" >&2
    exit 1
  fi
}

run_maptest

# =============================================================================
# WORKLOADS — strings first, then one table drives every category in order.
# Row: num|title|strace_set|perf_set|workload_var|category|flags
# Empty strace_set skips the strace cell; flags understands `kbuild_setup`.
# =============================================================================
EXEC_WORKLOAD="sudo -u \$SUDO_USER stress-ng --exec 4 --exec-ops $EXEC_OPS"
OPEN_WORKLOAD="stress-ng --open 4 --open-ops $OPEN_OPS"
MMAP_WORKLOAD="stress-ng --mmap 4 --mmap-mprotect --mmap-bytes 4K --mmap-ops $MMAP_OPS"
# `find -exec touch` refreshes Go mtimes only (git-neutral); output to /tmp.
GOBUILD_WORKLOAD="cd \"\$SCRIPT_DIR\" && find . -name '*.go' -exec touch {} + && go build -o /tmp/muon_build_test ."
# Highest sustained rate in the suite (~1M EPS); metrics preserved per-run.
BRK_WORKLOAD="stress-ng --brk 4 --brk-ops $BRK_OPS --metrics-brief"
# Unix-socket flood (~100k connects/s); exercises the connect Unix path.
CONN_WORKLOAD="rm -f /tmp/muon_conn_test.sock; python3 \"\$SCRIPT_DIR\"/bench/conn_flood.py server \$(( $CONN_OPS + 60 )) & SRV=\$!; sleep 0.5; for i in \$(seq 1 50); do python3 \"\$SCRIPT_DIR\"/bench/conn_flood.py client 1 >/dev/null 2>&1 && break; sleep 0.1; done; python3 \"\$SCRIPT_DIR\"/bench/conn_flood.py client $CONN_OPS; RC=\$?; kill -KILL \$SRV 2>/dev/null; wait \$SRV 2>/dev/null; rm -f /tmp/muon_conn_test.sock; exit \$RC"
# Thread churn hits the fork probe's thread path (K1 surface).
PTHREAD_WORKLOAD="stress-ng --pthread 4 --pthread-ops $PTHREAD_OPS"
# -j4 matches the 4 pinned workload cores.
KBUILD_WORKLOAD="make -C \"\$KERNEL_SRC\" clean >/dev/null && make -C \"\$KERNEL_SRC\" -j4"

CATEGORY_TABLE=(
  "1|exec-heavy|execve,exit|execve,exit|EXEC_WORKLOAD|exec|"
  "2|openat-heavy|openat|openat|OPEN_WORKLOAD|open|"
  "3|mmap-heavy|mmap,brk,munmap|mmap,brk,munmap|MMAP_WORKLOAD|mmap|"
  "4|go-build|execve,exit,openat,mmap,brk,munmap|execve,exit,openat,mmap,brk,munmap|GOBUILD_WORKLOAD|gobuild|"
  "5|kernel-compile|execve,exit,openat,mmap,brk,munmap|execve,exit,openat,mmap,brk,munmap|KBUILD_WORKLOAD|kbuild|kbuild_setup"
  "6|brk-heavy|brk|brk|BRK_WORKLOAD|brk|"
  "7|connect-heavy|connect|connect|CONN_WORKLOAD|connect|"
  "8|pthread-churn||clone,clone3|PTHREAD_WORKLOAD|pthread|"
)

# One untimed defconfig + narrowed rounds for the ~10-minute kernel builds.
kbuild_prepare() {
  KERNEL_SRC="${KERNEL_SRC:-$HOME/linux}"
  if [ ! -f "$KERNEL_SRC/Makefile" ]; then
    echo "ABORT: no kernel tree at $KERNEL_SRC (Makefile missing)." >&2
    echo "Set KERNEL_SRC to a configured kernel tree, then re-run." >&2
    exit 1
  fi
  export KERNEL_SRC
  if ! make -C "$KERNEL_SRC" defconfig >/dev/null 2>&1; then
    echo "ABORT: make -C $KERNEL_SRC defconfig failed." >&2
    exit 1
  fi
  SAVED_ITERATIONS="$ITERATIONS"
  SAVED_WARMUP="$WARMUP"
  ITERATIONS=3
  WARMUP=1
}

run_all_categories() {
  local row num title strace_set perf_set wl_var category flags workload
  local -a specs
  for row in "${CATEGORY_TABLE[@]}"; do
    IFS='|' read -r num title strace_set perf_set wl_var category flags <<< "$row"
    workload="${!wl_var}"
    echo ""
    echo "========================================="
    echo " CATEGORY $num: $title"
    echo "========================================="
    if [[ "$flags" == *kbuild_setup* ]]; then
      if [[ "$PUBLICATION" -ne 1 ]]; then
        echo "  [publication-skip] kernel-compile requires --publication"
        continue
      fi
      kbuild_prepare
    fi
    specs=("Baseline|||$workload|$category")
    [ -n "$strace_set" ] && specs+=("strace|strace -f -e trace=$strace_set -o /dev/null||$workload|$category")
    specs+=("perf trace|perf trace -e $perf_set -o /dev/null --||$workload|$category")
    specs+=("Muon||$MUON_BIN attach -p $$ --headless|$workload|$category")
    run_category_rounds "${specs[@]}"
    if [[ "$flags" == *kbuild_setup* ]]; then
      ITERATIONS="$SAVED_ITERATIONS"
      WARMUP="$SAVED_WARMUP"
    fi
  done
}
run_all_categories

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
  awk -F',' -v exec_ops="$EXEC_OPS" -v open_ops="$OPEN_OPS" -v mmap_ops="$MMAP_OPS" -v brk_ops="$BRK_OPS" -v conn_ops="$CONN_OPS" -v pthread_ops="$PTHREAD_OPS" '
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
      verdict = (gap <= 2 * sqrt(St * St + Sb * Sb)) ? "NOISE" : "REAL"
      if (cat == "exec") ops = exec_ops
      else if (cat == "open") ops = open_ops
      else if (cat == "mmap") ops = mmap_ops
      else if (cat == "brk") ops = brk_ops
      else if (cat == "connect") ops = conn_ops
      else if (cat == "pthread") ops = pthread_ops
      else ops = 0
      # RULE MIRROR: overhead/err/verdict formulas are duplicated in
      # bench/report.sh (render_markdown/render_json) and in the python
      # comparison inside run_regress. Keep all three in sync.
      # nz() kills negative zero ("-0", "-0.0%") from rounding tiny values.
      if (ops > 0) per_event = nz(sprintf("%.0f", (T - B) * 1e9 / ops))
      else per_event = "-"
      printf "%-12s %-20s %-12s %-10s %-13s %-10s\n", cat, $2, sprintf("%.1f%%", nz(oh)), sprintf("±%.1f%%", err), per_event, verdict
    }
    function nz(x) { return (x == 0) ? 0 : x }
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
  echo "  Verdict: NOISE when |tracer_avg - baseline_avg| <= 2 * sqrt(tracer_stddev^2 + baseline_stddev^2), else REAL"
  echo "  stddev is the sample (n-1) deviation of the trimmed runs."
  echo "  Per-event ns divides by configured ops; stress-ng quantizes exec ops"
  echo "  into fork batches (actual usually exceeds configured), so exec"
  echo "  per-event figures are approximate — worse in --fast mode."
fi
echo ""

# =============================================================================
# ARCHIVE THIS RUN (results + env + metadata under bench/results/<stamp>)
# =============================================================================
DEST="$SCRIPT_DIR/bench/results/$STAMP"
mkdir -p "$DEST" 2>/dev/null || echo "WARNING: could not create archive dir $DEST." >&2
if [ -f "$RESULTS_FILE" ]; then
  cp "$RESULTS_FILE" "$DEST/results.csv" 2>/dev/null || echo "WARNING: could not archive results.csv." >&2
fi
if [ -f "$ENV_FILE" ]; then
  cp "$ENV_FILE" "$DEST/env.txt" 2>/dev/null || echo "WARNING: could not archive env.txt." >&2
fi
{
  echo "date_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode: FAST=$FAST_MODE MUON_ONLY=$MUON_ONLY TRACERS_ONLY=$TRACERS_ONLY PUBLICATION=$PUBLICATION SWEEP=$SWEEP"
  echo "iterations: $ITERATIONS"
  echo "warmup: $WARMUP"
  if [ -f "$RESULTS_FILE" ]; then
    first_line=$(head -n 1 "$RESULTS_FILE" 2>/dev/null)
    [[ "$first_line" == coremap:* ]] && echo "$first_line"
  fi
} > "$DEST/meta.txt"
echo "Results archived to bench/results/$STAMP"
ARCHIVED=1

# =============================================================================
# REGRESSION GATE (--regress[=warn|fail])
# =============================================================================

# Compares this run's overheads against bench/baseline.json (written by
# bench/report.sh --init-baseline). Runs after the archive so the archived
# results.csv exists whatever the verdict. Returns 1 only when mode=fail and
# at least one cell fails; warn mode always returns 0.
run_regress() {
  BASELINE_JSON="$SCRIPT_DIR/bench/baseline.json"

  if [ ! -f "$BASELINE_JSON" ]; then
    echo "REGRESS SKIPPED: no bench/baseline.json (create one with: bench/report.sh <results-dir> --init-baseline)"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "REGRESS ERROR: python3 required to evaluate" >&2
    return 2
  fi

  # Comparison logic lives in bench/regress.py (same formulas as the awk
  # summary; the baseline stores independently measured overheads, so
  # only the deltas between the two are comparable).
  python3 "$SCRIPT_DIR/bench/regress.py" "$RESULTS_FILE" "$BASELINE_JSON" "$REGRESS"
}

if [[ "$REGRESS" != "off" ]]; then
  run_regress
fi
