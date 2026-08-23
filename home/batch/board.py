#!/usr/bin/env python3
# Batch board renderer. Reads `pueue status --json` on stdin, group filter as argv[1] (optional).
import sys, json, subprocess, datetime

group = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    d = json.loads(sys.stdin.read() or "{}")
except Exception:
    d = {}
tasks = d.get("tasks", {})
if group:
    tasks = {k: v for k, v in tasks.items() if v.get("group") == group}


def state(t):
    s = t.get("status")
    if isinstance(s, str):
        return s
    if isinstance(s, dict):
        if "Done" in s:
            return "Success" if s["Done"].get("result") == "Success" else "Failed"
        return next(iter(s))
    return str(s)


def detail(k, st):
    if st not in ("Running", "Failed"):
        return ""
    try:
        out = subprocess.run(["pueue", "log", k, "--lines", "150"],
                             capture_output=True, text=True, timeout=4).stdout
    except Exception:
        return ""
    lines = out.splitlines()
    prog = [l for l in lines if "@progress" in l]
    if prog:
        return "» " + prog[-1].split("@progress", 1)[1].strip()[:66]
    if st == "Failed":
        fl = [l for l in lines if "@batch FAIL" in l]
        if fl:
            return "✗ " + fl[-1].split("@batch FAIL", 1)[1].strip()[:66]
    if st == "Running":
        nb = [l for l in lines if l.strip() and not l.startswith(("---", "Command", "Path", "Label", "Start"))]
        if nb:
            return nb[-1].strip()[:68]
    return ""


rows = []
nd = nr = nf = nq = 0
for k, t in sorted(tasks.items(), key=lambda x: int(x[0])):
    st = state(t)
    if st == "Success":
        nd += 1; c, m = "32", "✓"
    elif st == "Failed":
        nf += 1; c, m = "31", "✗"
    elif st == "Running":
        nr += 1; c, m = "33", "▶"
    else:
        nq += 1; c, m = "90", "·"
    rows.append((k, c, m, (t.get("label") or "")[:16], st, detail(k, st)))

n = len(tasks); tot = n or 1
fill = int(40 * nd / tot); bar = "#" * fill + "." * (40 - fill)
hdr = "· " + group if group else "(all groups)"
print(f"\033[1m BATCH BOARD\033[0m {hdr}   {datetime.datetime.now():%H:%M:%S}")
print(f" [{bar}] {nd}/{n} done · \033[33m{nr} run\033[0m · \033[31m{nf} fail\033[0m · {nq} queued")
print(" " + "─" * 74)
for k, c, m, label, st, prog in rows:
    print(f"  \033[{c}m{m} {k:>3} {label:<16}\033[0m {st:<8} {prog}")
if not rows:
    print("  (no jobs" + (f" in group '{group}'" if group else "") + ")")
print(" " + "─" * 74)
print(" \033[90mview: batch view <id> · follow: batch follow <id> · retry: batch retry <group>\033[0m")
if nf:
    print(f" \033[31m {nf} FAILED — `batch retry {group or '<group>'}` to restart\033[0m")
