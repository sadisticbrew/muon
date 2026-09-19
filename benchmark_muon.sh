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

# CPU Core Pinning
WORKLOAD_CORES="4,5,6,7"
MUON_CORE="0"

# Dev mode vs Full mode
FAST_MODE=0
MUON_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --fast) FAST_MODE=1 ;;
    --muon-only) MUON_ONLY=1 ;;
    *)
      echo "Unknown option: $arg (supported: --fast, --muon-only)"
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

    echo "============================================="
    echo " Muon Benchmark Suite [FAST DEV MODE]"
    echo "============================================="
else
    ITERATIONS=7
    EXEC_OPS=10000
    OPEN_OPS=300000
    MMAP_OPS=15000

    MIXED_EXEC_OPS=2000
    MIXED_OPEN_OPS=100000
    MIXED_MMAP_OPS=5000

    echo "============================================="
    echo " Muon Benchmark Suite [FULL MODE]"
    echo "============================================="
fi

# Muon-only mode keeps its own results file so it never clobbers a full run.
if [[ "$MUON_ONLY" -eq 1 ]]; then
  RESULTS_FILE="/tmp/muon_bench_muon_only.txt"
  echo " MUON ONLY — baseline/strace/perf trace skipped, no overhead% in summary"
fi

> "$RESULTS_FILE"

for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  echo performance > "$gov_file" 2>/dev/null
done

restore_governors() {
  for gov_file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo powersave > "$gov_file" 2>/dev/null
  done
}
trap restore_governors EXIT

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
maybe_run() {
  if [[ "$MUON_ONLY" -eq 1 && "$1" != "Muon" ]]; then
    echo "  [muon-only] skipping $1"
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
# run_benchmark "strace" "strace -f -e trace=openat -o /dev/null" "" "$OPEN_WORKLOAD" "open"
# run_benchmark "perf trace" "perf trace -e openat -o /dev/null --" "" "$OPEN_WORKLOAD" "open"
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
else
  echo "Overhead calculation:"
  echo "  overhead% = ((tracer_avg - baseline_avg) / baseline_avg) * 100"
fi
echo ""
