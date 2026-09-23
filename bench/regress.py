#!/usr/bin/env python3
import json
import math
import re
import sys


def main():
    csv_path, baseline_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]

    try:
        with open(baseline_path) as fh:
            baseline = json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"REGRESS ERROR: cannot read baseline {baseline_path}: {exc}", file=sys.stderr)
        return 2

    # Fail closed on wrong-shaped baselines (a list, a string cells map, a
    # non-numeric capacity): comparing against garbage must never pass.
    if not isinstance(baseline, dict) or not isinstance(baseline.get("cells", {}), dict):
        print(f"REGRESS ERROR: baseline {baseline_path} has no object 'cells' map", file=sys.stderr)
        return 2

    base_cells = baseline.get("cells") or {}
    base_cap = baseline.get("capacity_ev_per_s")
    if base_cap is not None and (isinstance(base_cap, bool) or not isinstance(base_cap, (int, float))):
        print(f"REGRESS ERROR: baseline capacity_ev_per_s is not a number", file=sys.stderr)
        return 2

    base_rows = {}
    new_cells = {}
    invalid = set()
    sweep_best = None

    try:
        with open(csv_path) as fh:
            for raw in fh:
                line = raw.strip()
                if not line:
                    continue
                if line.startswith("coremap:"):
                    continue
                if line.startswith("sweep:"):
                    ev = re.search(r"ev_per_s=(\d+)", line)
                    st = re.search(r"status=(\w+)", line)
                    if ev and st and st.group(1) == "CLEAN":
                        val = int(ev.group(1))
                        if sweep_best is None or val > sweep_best:
                            sweep_best = val
                    continue
                parts = line.split(",")
                if len(parts) < 4:
                    continue
                cat, name, avg_s = parts[0], parts[1], parts[2]
                key = f"{cat}:{name}"
                if avg_s == "INVALID":
                    invalid.add(key)
                    continue
                try:
                    avg = float(avg_s)
                    sd = float(parts[3])
                except ValueError:
                    continue
                if name == "Baseline":
                    base_rows[cat] = (avg, sd)
                else:
                    new_cells[key] = (avg, sd)
    except OSError as exc:
        print(f"REGRESS ERROR: cannot read results {csv_path}: {exc}", file=sys.stderr)
        return 2

    # A null/missing stored overhead means "no baseline for this cell" (e.g.
    # the baseline came from a partial run) — SKIP, never default to 0.0,
    # which would manufacture a false FAIL against any real measurement.
    def baseline_oh_err(key):
        cell = base_cells.get(key)
        if not isinstance(cell, dict):
            return None
        oh, er = cell.get("overhead_pct"), cell.get("overhead_err")
        if oh is None or er is None:
            return None
        try:
            return float(oh), float(er)
        except (TypeError, ValueError):
            return None

    rows = []
    notes = []
    fails = 0
    warns = 0

    for key in sorted(new_cells):
        cat = key.split(":", 1)[0]
        base = base_rows.get(cat)
        if base is None or base[0] == 0:
            if key in base_cells:
                rows.append((key, baseline_oh_err(key)[0], None, None, "SKIP"))
            notes.append(f"REGRESS NOTE: {key} skipped — no Baseline cell for '{cat}' in this run")
            continue
        if key not in base_cells:
            notes.append(f"REGRESS NOTE: {key} is NEW (not in baseline; info only)")
            continue

        T, St = new_cells[key]
        B, Sb = base
        new_oh = (T - B) / B * 100.0
        new_err = 100.0 * math.sqrt((St / B) ** 2 + (T * Sb / (B * B)) ** 2)
        bo = baseline_oh_err(key)
        if bo is None:
            rows.append((key, None, new_oh, None, "SKIP"))
            notes.append(f"REGRESS NOTE: {key} skipped — no stored overhead in baseline (partial baseline?)")
            continue
        base_oh, base_err = bo
        gap = new_oh - base_oh
        noise = 2.0 * math.sqrt(new_err ** 2 + base_err ** 2)
        # EPS keeps IEEE754 dust (e.g. 3.000000000000007) from flipping a
        # verdict sitting exactly on a threshold.
        EPS = 1e-9

        if gap > 3.0 + EPS and gap > noise:
            if mode == "fail":
                verdict = "FAIL"
                fails += 1
            else:
                verdict = "WARN"
                warns += 1
        elif gap > 3.0 + EPS:
            verdict = "WARN"
            warns += 1
        elif gap < -3.0 - EPS and abs(gap) > noise:
            verdict = "IMPROVED"
        else:
            verdict = "OK"
        rows.append((key, base_oh, new_oh, gap, verdict))

    for key in sorted(base_cells):
        if key in new_cells:
            continue
        if key.split(":", 1)[-1] == "Baseline":
            continue  # reference row, not a candidate — no note, no row
        state = "INVALID in this run" if key in invalid else "missing from this run"
        stored = baseline_oh_err(key)
        rows.append((key, stored[0] if stored else None, None, None, "SKIP"))
        notes.append(f"REGRESS NOTE: {key} skipped ({state}; never fails)")

    print("")
    print("REGRESS REPORT")
    print(f"{'Cell':<26} {'Base%':>9} {'New%':>9} {'Gap':>9}  Verdict")
    print("-" * 68)
    for key, base_oh, new_oh, gap, verdict in rows:
        b = "n/a" if base_oh is None else f"{base_oh:+.2f}"
        n = "n/a" if new_oh is None else f"{new_oh:+.2f}"
        g = "n/a" if gap is None else f"{gap:+.2f}"
        print(f"{key:<26} {b:>9} {n:>9} {g:>9}  {verdict}")
    for note in notes:
        print(note)

    if sweep_best is not None and base_cap is not None:
        # Boundary is exclusive and exact: integers on both sides, so exactly
        # 80% passes. Advisory only — capacity never fails a run.
        if base_cap and sweep_best < 0.8 * base_cap:
            warns += 1
            print(f"REGRESS CAPACITY: WARN — CLEAN {sweep_best} events/s < 0.8 x baseline {base_cap} events/s")
        else:
            print(f"REGRESS CAPACITY: OK — CLEAN {sweep_best} events/s vs baseline {base_cap} events/s")
    elif sweep_best is not None:
        print(f"REGRESS CAPACITY: {sweep_best} events/s (baseline has no capacity figure; info only)")
    else:
        print("REGRESS CAPACITY: no CLEAN sweep in this run (info only)")

    if fails > 0:
        # fails can only be non-zero in fail mode (warn mode counts them as
        # WARN above), so this is unconditionally a failure.
        print(f"REGRESS FAIL ({fails})")
        return 1
    if warns > 0:
        print(f"REGRESS PASS ({warns} warning(s))")
    else:
        print("REGRESS PASS")
    return 0


sys.exit(main())
