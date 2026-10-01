#!/usr/bin/env python3
"""Amendment 12 step 1: list the tool-define branches in final champion RTL.

For every run directory under bench/v2/<model>/rep<N>/final-rtl, print each
`ifdef / `ifndef / `elsif whose macro is not RISCV_FORMAL_ALTOPS and not an
include guard (an `ifndef X directly followed by `define X), with the number
of lines in each arm. The classification the amendment asks for ((a) state
before the start marker only, (b) formal-only structure or parameter,
(c) simulated and synthesized behavior differ after the marker, (d) other) is
done by reading the listed branches; this script only finds them.

    research/v2/scripts/tool_branches.py bench/v2 [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

DIRECTIVE = re.compile(r"^\s*`(ifdef|ifndef|elsif|else|endif|define)\b\s*([A-Za-z_][A-Za-z0-9_]*)?")
SANCTIONED = {"RISCV_FORMAL_ALTOPS"}


def branches(path: Path) -> list[dict]:
    lines = path.read_text(errors="replace").splitlines()
    found, stack = [], []
    for i, line in enumerate(lines, 1):
        m = DIRECTIVE.match(line)
        if not m:
            continue
        kind, name = m.group(1), m.group(2)
        if kind in ("ifdef", "ifndef"):
            nxt = next((DIRECTIVE.match(l) for l in lines[i:] if DIRECTIVE.match(l)), None)
            body = next((l.strip() for l in lines[i:] if l.strip()), "")
            # `ifndef X / `define X, or `ifndef X / `include "<pkg>" (the package defines X)
            guard = kind == "ifndef" and ((nxt and nxt.group(1) == "define" and nxt.group(2) == name)
                                          or body.startswith("`include"))
            stack.append({"file": path.name, "line": i, "directive": kind, "macro": name,
                          "guard": bool(guard), "arms": [i]})
        elif kind in ("elsif", "else") and stack:
            stack[-1]["arms"].append(i)
            if kind == "elsif":
                stack[-1].setdefault("elsif", []).append(name)
        elif kind == "endif" and stack:
            b = stack.pop()
            b["arms"].append(i)
            b["arm_lines"] = [b["arms"][k + 1] - b["arms"][k] - 1 for k in range(len(b["arms"]) - 1)]
            macros = {b["macro"], *b.get("elsif", [])}
            if not b["guard"] and not macros <= SANCTIONED:
                found.append({k: b[k] for k in ("file", "line", "directive", "macro", "arm_lines")}
                             | ({"elsif": b["elsif"]} if "elsif" in b else {}))
    return sorted(found, key=lambda b: b["line"])


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("root", type=Path, help="results dir holding <model>/rep<N>/final-rtl")
    ap.add_argument("--json", type=Path)
    args = ap.parse_args()
    out = {}
    for rtl in sorted(args.root.glob("*/rep*/final-rtl")):
        run = f"{rtl.parent.parent.name} {rtl.parent.name}"
        out[run] = [b for f in sorted(rtl.glob("*.sv")) + sorted(rtl.glob("*.svh")) + sorted(rtl.glob("*.v"))
                    for b in branches(f)]
    print("| run | file:line | directive | macro | lines per arm |")
    print("|---|---|---|---|---|")
    for run, bs in out.items():
        if not bs:
            print(f"| {run} | (none) | | | |")
        for b in bs:
            macro = b["macro"] + "".join(f" / elsif {e}" for e in b.get("elsif", []))
            print(f"| {run} | {b['file']}:{b['line']} | `{b['directive']} | {macro} | "
                  f"{', '.join(map(str, b['arm_lines']))} |")
    if args.json:
        args.json.write_text(json.dumps(out, indent=2) + "\n")


if __name__ == "__main__":
    main()
