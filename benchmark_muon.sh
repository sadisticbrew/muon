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

# CPU Core Pinning
WORKLOAD_CORES="4,5,6,7"
MUON_CORE="0"

# Dev mode vs Full mode
FAST_MODE=0
MUON_ONLY=0
TRACERS_ONLY=0
WARMUP=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    --muon-only) MUON_ONLY=1 ;;
    --tracers-only) TRACERS_ONLY=1 ;;
    *)
      echo "Unknown option: $arg (supported: --fast, --muon-only, --tracers-only)"
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
  /tmp/muon_cell_*.times /tmp/muon_lastres.txt /tmp/muon_time.txt

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

# =============================================================================
# STATS HELPER
# =============================================================================

calculate_stats() {
  local values=("$@")
  local count=${#values[@]}

  if [ "$count" -lt 3 ]; then
    echo "0.000 0.000"
    return 1
  fi

  local sorted=($(printf '%s\n' "${values[@]}" | sort -n))
  local trimmed=("${sorted[@]:1:$((count - 2))}")

  printf '%s\n' "${trimmed[@]}" | awk '{
    sum += $1;
    sumsq += ($1 * $1);
    n++
  } END {
    if (n > 0) {
      mean = sum / n;
      variance = (sumsq / n) - (mean * mean);
      if (variance < 0) variance = 0;
      printf "%.3f %.3f", mean, sqrt(variance);
    } else {
      printf "0.000 0.000";
    }
  }'
}

# =============================================================================
# CORE BENCHMARK FUNCTION
# =============================================================================

# Wrapper: in muon-only mode, skip every tracer whose name isn't "Muon".
# In tracers-only mode, skip Baseline and Muon.
maybe_run() {
  if [[ "$MUON_ONLY" -eq 1 && "$1" != "Muon" ]]; then
    echo "  [muon-only] skipping $1"
    return 0
  fi
  if [[ "$TRACERS_ONLY" -eq 1 && ( "$1" == "Baseline" || "$1" == "Muon" ) ]]; then
    echo "  [tracers-only] skipping $1"
    return 0
  fi
  run_benchmark "$@"
}

run_benchmark() {
  local name="$1"
  local prefix_cmd="$2"
  local bg_cmd="$3"
  local workload="$4"
  local category="$5"
  local times=()
  local dropped_runs=0

  echo ""
  echo "--- $name ---"

  for i in $(seq 1 $ITERATIONS); do
    sync
    echo 3 > /proc/sys/vm/drop_caches
    sleep 0.5

    local muon_pid=""
    local muon_log="/tmp/muon_run_$i.log"
    if [ -n "$bg_cmd" ]; then
      taskset -c "$MUON_CORE" $bg_cmd > "$muon_log" 2>&1 &
      muon_pid=$!
    fi

    sleep 1

    local muon_ready=1
    if [ -n "$muon_pid" ]; then
      if ! kill -0 "$muon_pid" 2>/dev/null; then
        echo "  Run $i: FATAL — Muon exited before the run started:"
        tail -n 10 "$muon_log" | sed 's/^/    /'
        muon_ready=0
      elif ! grep -q "Muon ready" "$muon_log" 2>/dev/null; then
        echo "  Run $i: FATAL — Muon never reported ready:"
        tail -n 10 "$muon_log" | sed 's/^/    /'
        muon_ready=0
      fi
      if [ "$muon_ready" -eq 0 ]; then
        kill "$muon_pid" 2>/dev/null
        wait "$muon_pid" 2>/dev/null
        rm -f "$muon_log"
        ((dropped_runs++))
        continue
      fi
    fi

    local time_output
    if [ -n "$prefix_cmd" ]; then
      time_output=$( { /usr/bin/time -f "%e" \
        taskset -c "$WORKLOAD_CORES" $prefix_cmd bash -c "$workload" \
        2>/tmp/muon_time.txt; } 2>/tmp/muon_time.txt; cat /tmp/muon_time.txt )
    else
      { /usr/bin/time -f "%e" \
        taskset -c "$WORKLOAD_CORES" bash -c "$workload" \
        2>/tmp/muon_time.txt; }
      time_output=$(cat /tmp/muon_time.txt)
    fi

    local run_time=$(tail -n 1 /tmp/muon_time.txt)

    local drop_warning=0
    if [ -n "$muon_pid" ]; then
      kill -SIGTERM "$muon_pid" > /dev/null 2>&1
      wait "$muon_pid" 2>/dev/null
      if grep -q "WARNING: Ring buffer was full" "$muon_log" 2>/dev/null; then
        drop_warning=1
      fi
      rm -f "$muon_log"
    fi

    if [ "$drop_warning" -eq 1 ]; then
      echo "  Run $i: ${run_time}s [DROPPED — ring buffer full]"
      ((dropped_runs++))
    else
      echo "  Run $i: ${run_time}s"
      times+=("$run_time")
    fi
  done

  local valid=${#times[@]}
  if [ "$valid" -lt 3 ]; then
    echo ">> INVALID: Only $valid clean runs (need 3+). <<"
    echo "$category,$name,INVALID,0.000,$valid,$dropped_runs" >> "$RESULTS_FILE"
    return
  fi

  local stats=($(calculate_stats "${times[@]}"))
  local avg=${stats[0]}
  local stddev=${stats[1]}

  echo ">> Average for $name: ${avg}s (±${stddev}s) | $valid clean runs, $dropped_runs dropped <<"
  echo "$category,$name,$avg,$stddev,$valid,$dropped_runs" >> "$RESULTS_FILE"
}

# =============================================================================
# WORKLOADS
# =============================================================================

# --- 1. EXEC-heavy ---
EXEC_WORKLOAD="sudo -u \$SUDO_USER stress-ng --exec 4 --exec-ops $EXEC_OPS"
echo ""
echo "========================================="
echo " CATEGORY 1: exec-heavy"
echo "========================================="
maybe_run "Baseline" "" "" "$EXEC_WORKLOAD" "exec"
maybe_run "strace" "strace -f -e trace=execve,exit -o /dev/null" "" "$EXEC_WORKLOAD" "exec"
maybe_run "perf trace" "perf trace -e execve,exit -o /dev/null --" "" "$EXEC_WORKLOAD" "exec"
maybe_run "Muon" "" "$MUON_BIN attach -p $$ --headless" "$EXEC_WORKLOAD" "exec"

# --- 2. OPEN-heavy ---
OPEN_WORKLOAD="stress-ng --open 4 --open-ops $OPEN_OPS"
echo ""
echo "========================================="
echo " CATEGORY 2: openat-heavy"
echo "========================================="
maybe_run "Baseline" "" "" "$OPEN_WORKLOAD" "open"
maybe_run "strace" "strace -f -e trace=openat -o /dev/null" "" "$OPEN_WORKLOAD" "open"
maybe_run "perf trace" "perf trace -e openat -o /dev/null --" "" "$OPEN_WORKLOAD" "open"
maybe_run "Muon" "" "$MUON_BIN attach -p $$ --headless" "$OPEN_WORKLOAD" "open"

# --- 3. MMAP-heavy ---
MMAP_WORKLOAD="stress-ng --mmap 4 --mmap-mprotect --mmap-bytes 4K --mmap-ops $MMAP_OPS"
echo ""
echo "========================================="
echo " CATEGORY 3: mmap-heavy"
echo "========================================="
maybe_run "Baseline" "" "" "$MMAP_WORKLOAD" "mmap"
maybe_run "strace" "strace -f -e trace=mmap,brk,munmap -o /dev/null" "" "$MMAP_WORKLOAD" "mmap"
maybe_run "perf trace" "perf trace -e mmap,brk,munmap -o /dev/null --" "" "$MMAP_WORKLOAD" "mmap"
maybe_run "Muon" "" "$MUON_BIN attach -p $$ --headless" "$MMAP_WORKLOAD" "mmap"

# --- 4. MIXED (Regression) ---
# MIXED_WORKLOAD="sudo -u \$SUDO_USER stress-ng --exec 2 --exec-ops $MIXED_EXEC_OPS --mmap 2 --mmap-mprotect --mmap-ops $MIXED_MMAP_OPS --open 2 --open-ops $MIXED_OPEN_OPS"
# echo ""
# echo "========================================="
# echo " CATEGORY 4: mixed (regression test)"
# echo "========================================="
# run_benchmark "Baseline" "" "" "$MIXED_WORKLOAD" "mixed"
# run_benchmark "strace" "strace -f -e trace=execve,exit,openat,mmap,brk -o /dev/null" "" "$MIXED_WORKLOAD" "mixed"
# run_benchmark "perf trace" "perf trace -e execve,exit,openat,mmap,brk -o /dev/null --" "" "$MIXED_WORKLOAD" "mixed"
# run_benchmark "Muon" "" "$MUON_BIN attach -p $$ --headless" "$MIXED_WORKLOAD" "mixed"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "================================================================="
echo " RESULTS SUMMARY"
echo "================================================================="
echo ""
printf "%-12s %-20s %-10s %-10s %-10s %-10s\n" "Category" "Tracer" "Avg(s)" "StdDev(s)" "CleanRuns" "Dropped"
printf "%-12s %-20s %-10s %-10s %-10s %-10s\n" "--------" "------" "------" "---------" "---------" "-------"

while IFS=',' read -r category name avg stddev valid dropped; do
  printf "%-12s %-20s %-10s %-10s %-10s %-10s\n" "$category" "$name" "$avg" "±$stddev" "$valid" "$dropped"
done < "$RESULTS_FILE"

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
fi
echo ""
