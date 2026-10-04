#!/usr/bin/env python3
"""Analysis 3: did implementation agents run the harness's checks themselves?

Source: each run's agent.full.log.gz (parsed by transcripts.py into
results/transcript_sessions.jsonl), joined to log.jsonl outcomes by
hypothesis id.

Detection: every shell command an implementation session ran (Claude Code
Bash tool_use; Codex command_execution items) is unwrapped (Codex's
`/bin/bash -c '...'`, nested `bash -c`), heredoc bodies are set aside, the
script is split into simple commands (on ; && || | & ( ) and newlines), and
leading VAR=value, timeout/nice/env/nohup/setsid wrappers are dropped. A
simple command counts as a check only when the check is the program being
run, never when it is read or searched (cat/sed/rg formal/run_all.sh, ps |
grep sby and `command -v sby` do not count):
  formal  bash|sh formal/run_all.sh, ./formal/run_all.sh, make formal|formal-deep,
          sby <file>.sby | sby -f, python -m tools.eval.formal
  cosim   make cosim, python -m tools.eval.cosim, test/cosim/run_cosim.py,
          the built Verilator harness cores/bench/obj_dir/cosim_sim, or Python
          calling tools.eval.cosim / run_coremark_ipc (CoreMark on the harness)
  lint    verilator --lint-only, make lint
  timing  make timing|fpga, python -m tools.eval.gowin|tools.eval.fpga, gw_sh,
          or Python calling tools.eval.gowin / gw_sh
  cocotb  pytest, python -m pytest, make test
  own_sim iverilog, vvp, verilator --binary|--cc|--exe|--build (an agent's own
          testbench rather than a harness check)
A check "covers the shipped RTL" when its last invocation comes after the
session's last RTL edit (Edit/Write or Codex file_change on cores/bench/rtl,
or a shell command that writes an rtl/*.sv path: sed -i, perl -i, redirect,
Python write_text/open(...,'w'), cp/mv into rtl, git checkout/restore/apply).
"""
from __future__ import annotations

import collections

import common as c
import transcripts as t

CHECKS = t.CHECKS


def main():
    sessions = [s for s in t.build_cache() if s["role"] in ("implementation", "hypothesis")]
    impl = {(s["model"], s["rep"], s["hyp_id"]): s for s in sessions if s["role"] == "implementation"}
    hyp = [s for s in sessions if s["role"] == "hypothesis"]

    slots = []
    unmatched = []
    for m in c.MODELS:
        for r in c.REPS:
            for d in c.candidates(m, r):
                cls = c.outcome_class(d)
                s = impl.get((m, r, d["id"]))
                if s is None:
                    unmatched.append((c.NAME[m], r, d["id"], cls))
                    continue
                gate_fail = cls not in ("accepted", "rejected_lost_to_sibling",
                                        "rejected_below_margin", "rejected_no_gain")
                slots.append({
                    "model": m, "rep": r, "id": d["id"], "class": cls,
                    "gate_fail": gate_fail,
                    "formal_fail": cls.startswith("formal_"),
                    "finished": s["finished"],
                    "n_cmd": s["n_cmd"],
                    "has": {k: s["checks"][k] > 0 for k in CHECKS},
                    "n": s["checks"],
                    "after_edit": s["check_after_last_edit"],
                    "local_formal": local_verdict(s),
                })

    def summarize(rows):
        n = len(rows)
        out = {"n_slots": n}
        for k in CHECKS:
            out[f"share_{k}"] = sum(r["has"][k] for r in rows) / n
        out["share_formal_after_last_edit"] = sum(r["after_edit"]["formal"] for r in rows) / n
        out["share_cosim_after_last_edit"] = sum(r["after_edit"]["cosim"] for r in rows) / n
        out["share_all_three"] = sum(r["has"]["formal"] and r["has"]["cosim"] and r["has"]["timing"] for r in rows) / n
        out["median_formal_runs_if_any"] = _median([r["n"]["formal"] for r in rows if r["has"]["formal"]])
        out["share_killed_at_watchdog"] = sum(not r["finished"] for r in rows) / n
        out["median_shell_cmds"] = _median([r["n_cmd"] for r in rows])
        with_f = [r for r in rows if r["has"]["formal"]]
        without_f = [r for r in rows if not r["has"]["formal"]]
        for label, grp in (("with_formal", with_f), ("without_formal", without_f)):
            out[f"n_{label}"] = len(grp)
            out[f"gate_fail_rate_{label}"] = (sum(r["gate_fail"] for r in grp) / len(grp)) if grp else None
            out[f"formal_fail_rate_{label}"] = (sum(r["formal_fail"] for r in grp) / len(grp)) if grp else None
        last = [r for r in rows if r["after_edit"]["formal"]]
        notlast = [r for r in rows if not r["after_edit"]["formal"]]
        out["n_formal_after_last_edit"] = len(last)
        out["formal_fail_rate_formal_after_last_edit"] = (sum(r["formal_fail"] for r in last) / len(last)) if last else None
        out["formal_fail_rate_not_after_last_edit"] = (sum(r["formal_fail"] for r in notlast) / len(notlast)) if notlast else None
        out["gate_fail_count"] = sum(r["gate_fail"] for r in rows)
        out["formal_fail_count"] = sum(r["formal_fail"] for r in rows)
        return out

    per_sys = {c.NAME[m]: summarize([s for s in slots if s["model"] == m]) for m in c.MODELS}
    overall = summarize(slots)

    # hypothesis agents: trial timing / formal runs while sizing an idea
    hyp_sys = {}
    for m in c.MODELS:
        hs = [s for s in hyp if s["model"] == m]
        n = len(hs)
        hyp_sys[c.NAME[m]] = {
            "n_sessions": n,
            **{f"share_{k}": sum(s["checks"][k] > 0 for s in hs) / n for k in CHECKS},
            "share_killed_at_watchdog": sum(not s["finished"] for s in hs) / n,
        }

    # last local formal verdict vs gate outcome
    def gate_group(cls):
        if cls.startswith("formal_"):
            return "formal gate failed"
        if cls.startswith("accepted") or cls.startswith("rejected"):
            return "passed all gates"
        return "other gate failed"
    verdict_tab = {}
    for name, grp in [(c.NAME[m], [x for x in slots if x["model"] == m]) for m in c.MODELS] + [("all", slots)]:
        tab = {v: collections.Counter(gate_group(x["class"]) for x in grp if x["local_formal"] == v) for v in VERDICTS}
        verdict_tab[name] = {v: dict(tab[v]) for v in VERDICTS}
    formal_fail_by_verdict = collections.Counter(
        (x["local_formal"], x["class"]) for x in slots if x["class"].startswith("formal_"))

    # failing slots: did the agent see it coming?
    fails = [s for s in slots if s["gate_fail"]]
    fail_rows = collections.Counter((c.NAME[s["model"]], s["class"], s["has"]["formal"]) for s in fails)

    data = {"per_system": per_sys, "overall": overall, "hypothesis_agents": hyp_sys,
            "local_formal_verdict_vs_gate": verdict_tab,
            "formal_gate_failures_by_local_verdict": [
                {"local_verdict": k[0], "class": k[1], "n": v} for k, v in sorted(formal_fail_by_verdict.items())],
            "slots_without_impl_session": unmatched,
            "failing_slots_by_class_and_formal_selfcheck": [
                {"system": k[0], "class": k[1], "ran_formal": k[2], "n": v} for k, v in sorted(fail_rows.items())],
            "rules": __doc__}

    p = lambda x: "" if x is None else f"{100 * x:.0f}%"
    lines = ["# Analysis 3: implementation agents' own checks before submitting", "",
             f"{overall['n_slots']} implementation sessions (36 runs x 45 slots, minus "
             f"{len(unmatched)} slots whose hypothesis agent failed, so no implementation ran).", "",
             "Share of implementation sessions that ran each check at least once:", ""]
    hdr = ["system", "slots", "formal", "formal after last RTL edit", "cosim", "Gowin timing", "cocotb",
           "lint", "own sim", "formal+cosim+timing", "killed at 30 min"]
    rows = []
    for name, s in list(per_sys.items()) + [("all", overall)]:
        rows.append([name, s["n_slots"], p(s["share_formal"]), p(s["share_formal_after_last_edit"]),
                     p(s["share_cosim"]), p(s["share_timing"]), p(s["share_cocotb"]), p(s["share_lint"]),
                     p(s["share_own_sim"]), p(s["share_all_three"]), p(s["share_killed_at_watchdog"])])
    lines += [c.md_table(hdr, rows), ""]
    lines += ["Gate failures (broken or placement_failed) by whether the session ran formal itself:", ""]
    hdr = ["system", "slots with formal", "gate-fail rate", "formal-fail rate",
           "slots without formal", "gate-fail rate", "formal-fail rate"]
    rows = []
    for name, s in list(per_sys.items()) + [("all", overall)]:
        rows.append([name, s["n_with_formal"], p(s["gate_fail_rate_with_formal"]), p(s["formal_fail_rate_with_formal"]),
                     s["n_without_formal"], p(s["gate_fail_rate_without_formal"]), p(s["formal_fail_rate_without_formal"])])
    lines += [c.md_table(hdr, rows), ""]
    lines += ["Formal-fail rate when the last formal self-check came after the last RTL edit vs not:", ""]
    hdr = ["system", "slots formal after last edit", "formal-fail rate", "other slots", "formal-fail rate"]
    rows = []
    for name, s in list(per_sys.items()) + [("all", overall)]:
        rows.append([name, s["n_formal_after_last_edit"], p(s["formal_fail_rate_formal_after_last_edit"]),
                     s["n_slots"] - s["n_formal_after_last_edit"], p(s["formal_fail_rate_not_after_last_edit"])])
    lines += [c.md_table(hdr, rows), ""]
    lines += ["Last local formal result the implementation agent saw (run_all.sh's \"Formal: N passed, M failed\" "
              "line in a command output), and how the slot then fared at the gates. pass_final: 0 failed, and both the "
              "run and the reading of its result came after the last RTL edit; pass_stale: 0 failed but the RTL changed afterwards; fail: the last result it saw had "
              "failures; none: it never saw a finished run.", ""]
    hdr = ["system"] + [f"{v}: n (formal-gate fails / other gate fails)" for v in VERDICTS]
    rows = []
    for name, tab in verdict_tab.items():
        cells = [name]
        for v in VERDICTS:
            d = tab[v]
            n = sum(d.values())
            cells.append(f"{n} ({d.get('formal gate failed', 0)} / {d.get('other gate failed', 0)})")
        rows.append(cells)
    lines += [c.md_table(hdr, rows), ""]
    rows = [[k[0], k[1], v] for k, v in sorted(formal_fail_by_verdict.items())]
    lines += ["Formal-gate failures by the agent's last local verdict:", "",
              c.md_table(["local verdict", "gate class", "n"], rows), ""]
    lines += ["Failing slots by class and whether the implementation agent ran formal:", ""]
    rows = [[k[0], k[1], "yes" if k[2] else "no", v] for k, v in sorted(fail_rows.items())]
    lines += [c.md_table(["system", "class", "ran formal", "n"], rows), ""]
    lines += ["Hypothesis agents (they may probe ideas before proposing them):", ""]
    hdr = ["system", "sessions", "formal", "cosim", "Gowin timing", "cocotb", "killed at 20 min"]
    rows = [[k, v["n_sessions"], p(v["share_formal"]), p(v["share_cosim"]), p(v["share_timing"]),
             p(v["share_cocotb"]), p(v["share_killed_at_watchdog"])] for k, v in hyp_sys.items()]
    lines += [c.md_table(hdr, rows), ""]
    c.write_outputs("a3_selfchecks", data, "\n".join(lines))


def local_verdict(s) -> str:
    """Last run_all.sh summary ("Formal: N passed, M failed") the agent saw:
    pass_final  0 failed, seen after the last RTL edit, and a formal run was
                started after that edit (so the result is for the shipped RTL)
    pass_stale  0 failed, but the RTL was edited afterwards
    fail        failures in the last summary it saw (shipped anyway)
    none        never saw a summary (its run had not finished, or it never looked)"""
    ls = s.get("last_formal_summary")
    if ls is None:
        return "none"
    if ls[1] > 0:
        return "fail"
    final = s.get("last_formal_summary_after_last_edit") and s["check_after_last_edit"]["formal"]
    return "pass_final" if final else "pass_stale"


VERDICTS = ("pass_final", "pass_stale", "fail", "none")


def _median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


if __name__ == "__main__":
    main()
