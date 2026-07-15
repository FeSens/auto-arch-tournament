"""Unit tests for the bench matrix runner.

Pure-function tests on enumeration, key validation, log parsing, and
summarization. The full subprocess-driven `run_one_job` path (a real
orchestrator invocation) is exercised by test_smoke.py (slow, opt-in);
this file also covers run_one_job's early-return forensics behavior
with clone_fixture stubbed out, since that doesn't need a real
orchestrator run.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

from tools.bench import preflight, runner
from tools.bench.runner import (
    JobSpec,
    ModelEntry,
    clone_fixture,
    enumerate_jobs,
    load_done_set,
    load_keyfile,
    load_models,
    parse_codex_cost_from_log,
    parse_opencode_cost_from_log,
    run_one_job,
    summarize_run,
    validate_keys,
)


# ---- model loading -----------------------------------------------------


def _write_models_yaml(p: Path, n: int) -> None:
    lines = ["models:"]
    for i in range(n):
        lines.append(f"  - name: m{i}")
        lines.append(f"    model: prov{i}/m{i}")
        lines.append(f"    key_env: KEY{i}")
    p.write_text("\n".join(lines) + "\n")


def test_load_models_round_trip(tmp_path: Path):
    p = tmp_path / "models.yaml"
    _write_models_yaml(p, 3)
    out = load_models(p)
    assert len(out) == 3
    assert out[0].name == "m0"
    assert out[0].model == "prov0/m0"
    assert out[0].key_env == "KEY0"


def test_load_models_empty_raises(tmp_path: Path):
    p = tmp_path / "models.yaml"
    p.write_text("models: []\n")
    with pytest.raises(ValueError):
        load_models(p)


# ---- done-set + enumeration -------------------------------------------


def test_load_done_set_skips_partial(tmp_path: Path):
    p = tmp_path / "results.jsonl"
    p.write_text(
        json.dumps({"model": "a", "rep": 1, "status": "done"}) + "\n"
        + json.dumps({"model": "a", "rep": 2, "status": "running"}) + "\n"
        + json.dumps({"model": "b", "rep": 1, "status": "timed_out"}) + "\n"
        + json.dumps({"model": "b", "rep": 2, "status": "failed"}) + "\n"
    )
    done = load_done_set(p)
    # done + timed_out + failed all count as terminal (don't retry)
    assert ("a", 1) in done
    assert ("b", 1) in done
    assert ("b", 2) in done
    # running is not terminal — retry it
    assert ("a", 2) not in done


def test_load_done_set_missing_file(tmp_path: Path):
    assert load_done_set(tmp_path / "absent.jsonl") == set()


def test_enumerate_jobs_skips_done():
    models = [
        ModelEntry(name="a", model="x/a", key_env="K"),
        ModelEntry(name="b", model="x/b", key_env="K"),
    ]
    done = {("a", 1), ("a", 2)}
    jobs = enumerate_jobs(models, reps=2, done=done)
    assert len(jobs) == 2
    assert {(j.model.name, j.rep) for j in jobs} == {("b", 1), ("b", 2)}


def test_enumerate_jobs_only_filter():
    models = [
        ModelEntry(name="a", model="x/a", key_env="K"),
        ModelEntry(name="b", model="x/b", key_env="K"),
    ]
    jobs = enumerate_jobs(models, reps=1, done=set(), only_models=["b"])
    assert len(jobs) == 1
    assert jobs[0].model.name == "b"


# ---- key validation ----------------------------------------------------


def test_validate_keys_finds_missing():
    jobs = [
        JobSpec(ModelEntry(name="a", model="x/a", key_env="HAS_KEY"), 1),
        JobSpec(ModelEntry(name="b", model="x/b", key_env="MISSING_KEY"), 1),
    ]
    env = {"HAS_KEY": "yes"}
    missing = validate_keys(jobs, env)
    assert missing == ["MISSING_KEY"]


def test_validate_keys_all_present():
    jobs = [JobSpec(ModelEntry(name="a", model="x/a", key_env="K"), 1)]
    env = {"K": "v"}
    assert validate_keys(jobs, env) == []


def test_validate_keys_skips_oauth_models():
    jobs = [
        JobSpec(ModelEntry(name="a", model="gpt-5.5",
                           key_env="", oauth=True, provider="codex"), 1),
        JobSpec(ModelEntry(name="b", model="anthropic/c", key_env="K"), 1),
    ]
    env = {"K": "v"}
    # OAuth model contributes nothing to needed-keys.
    assert validate_keys(jobs, env) == []
    # Missing the API key for the non-OAuth model still flagged.
    assert validate_keys(jobs, {}) == ["K"]


def test_load_keyfile_parses_simple(tmp_path: Path):
    f = tmp_path / "keys.env"
    f.write_text(textwrap.dedent("""
        # comment line
        ANTHROPIC_API_KEY=sk-ant-test
        OPENAI_API_KEY = "sk-openai-test"
        OPENROUTER_API_KEY='sk-or-test'

        # blank line above
    """).strip() + "\n")
    out = load_keyfile(f)
    assert out["ANTHROPIC_API_KEY"] == "sk-ant-test"
    assert out["OPENAI_API_KEY"] == "sk-openai-test"
    assert out["OPENROUTER_API_KEY"] == "sk-or-test"


def test_load_keyfile_missing_returns_empty(tmp_path: Path):
    assert load_keyfile(tmp_path / "absent") == {}


# ---- codex cost parsing -----------------------------------------------


def test_parse_codex_cost_sums_turn_completed(tmp_path: Path):
    """Sum input_tokens (gross) + output_tokens + reasoning_output_tokens."""
    p = tmp_path / "agent.log"
    p.write_text(
        json.dumps({"type": "turn.completed",
                    "usage": {"input_tokens": 1000, "cached_input_tokens": 800,
                              "output_tokens": 200,
                              "reasoning_output_tokens": 50}}) + "\n"
        + json.dumps({"type": "command_execution"}) + "\n"
        + json.dumps({"type": "turn.completed",
                      "usage": {"input_tokens": 500, "cached_input_tokens": 400,
                                "output_tokens": 100,
                                "reasoning_output_tokens": 25}}) + "\n"
    )
    toks_in, toks_out, cost = parse_codex_cost_from_log(p)
    assert toks_in == 1500   # gross input (cache included)
    assert toks_out == 375   # 200+50 + 100+25
    assert cost == 0.0       # OAuth — no per-call billing


def test_parse_codex_cost_handles_missing_file(tmp_path: Path):
    assert parse_codex_cost_from_log(tmp_path / "absent") == (0, 0, 0.0)


def test_parse_codex_cost_dedups_repeated_lines(tmp_path: Path):
    """collect_agent_logs can concatenate the same hypothesis log twice;
    the parser must dedup by line content."""
    p = tmp_path / "agent.log"
    line = json.dumps({"type": "turn.completed",
                       "usage": {"input_tokens": 1000, "output_tokens": 100,
                                 "reasoning_output_tokens": 0}})
    p.write_text(line + "\n" + line + "\n" + line + "\n")
    toks_in, _toks_out, _cost = parse_codex_cost_from_log(p)
    assert toks_in == 1000  # counted once, not three times


# ---- opencode cost parsing --------------------------------------------


def test_parse_opencode_cost_includes_cache_and_reasoning(tmp_path: Path):
    """Gross input = tokens.input + cache.read + cache.write.
    Output = tokens.output + tokens.reasoning."""
    p = tmp_path / "agent.log"
    p.write_text(
        json.dumps({"type": "step_finish",
                    "part": {"tokens": {"input": 100, "output": 50,
                                         "reasoning": 200,
                                         "cache": {"read": 800, "write": 0}},
                              "cost": 0}}) + "\n"
    )
    toks_in, toks_out, cost = parse_opencode_cost_from_log(p)
    assert toks_in == 900    # 100 + 800 + 0
    assert toks_out == 250   # 50 + 200
    assert cost == 0.0


def test_parse_opencode_cost_handles_missing_file(tmp_path: Path):
    assert parse_opencode_cost_from_log(tmp_path / "absent") == (0, 0, 0.0)


# ---- summarize_run -----------------------------------------------------


def test_summarize_run_reads_run_summary_json(tmp_path: Path):
    """summarize_run loads the orchestrator-emitted run_summary.json
    verbatim and folds in token counts from agent.log."""
    log = tmp_path / "log.jsonl"
    log.write_text("")  # not consulted under the new contract
    (tmp_path / "run_summary.json").write_text(json.dumps({
        "iterations":      4,
        "accepted":        2,
        "rejected":        1,
        "broken":          1,
        "broken_by_class": {"formal_failed": 1},
        "baseline_fitness": 300.0,
        "final_fitness":    320.0,
        "best_fitness":     320.0,
        "best_round":       4,
        "delta_pct":        (20.0 / 300.0 * 100),
    }))
    agent = tmp_path / "agent.log"
    agent.write_text(
        json.dumps({"type": "turn.completed",
                    "usage": {"input_tokens": 1000, "output_tokens": 200,
                              "reasoning_output_tokens": 0}}) + "\n"
    )
    summary = summarize_run(log, agent, provider="codex")
    assert summary["iterations"] == 4
    assert summary["accepted"] == 2
    assert summary["rejected"] == 1
    assert summary["broken"] == 1
    assert summary["broken_by_class"] == {"formal_failed": 1}
    assert summary["final_fitness"] == 320.0
    assert summary["best_fitness"] == 320.0
    assert summary["best_round"] == 4
    assert summary["baseline_fitness"] == 300.0
    assert summary["delta_pct"] is not None
    assert abs(summary["delta_pct"] - (20.0 / 300.0 * 100)) < 1e-6
    # Token counts always come from agent.log (provider-specific cost
    # parsing); not in scope of run_summary.json.
    assert summary["total_tokens_in"] == 1000
    assert summary["total_tokens_out"] == 200


def test_summarize_run_missing_summary_flags_row(tmp_path: Path):
    """If run_summary.json is absent (orchestrator crashed before its
    first emit, or pre-Phase-2 orchestrator), the row carries
    summary_missing=True instead of silently scoring 0/0/0 from a
    log.jsonl fallback we used to have."""
    summary = summarize_run(tmp_path / "absent.jsonl", tmp_path / "absent.log")
    assert summary["iterations"] == 0
    assert summary["accepted"] == 0
    assert summary["final_fitness"] is None
    assert summary["best_fitness"] is None
    assert summary.get("summary_missing") is True


def test_summarize_run_malformed_json_flags_row(tmp_path: Path):
    """Mid-write or corrupt run_summary.json behaves like an absent file."""
    log = tmp_path / "log.jsonl"
    log.write_text("")
    (tmp_path / "run_summary.json").write_text("not json {")
    agent = tmp_path / "agent.log"
    agent.write_text("")
    summary = summarize_run(log, agent, provider="codex")
    assert summary.get("summary_missing") is True
    assert summary["iterations"] == 0


def test_summarize_run_carries_best_fpga_fields(tmp_path: Path):
    """LUT4/FF/Fmax/IPC of the best-fitness entry propagate from
    run_summary.json into the per-rep results.jsonl row, so downstream
    consumers (LEADERBOARD, plots, postmortems) don't have to join from
    log.jsonl."""
    log = tmp_path / "log.jsonl"
    log.write_text("")
    (tmp_path / "run_summary.json").write_text(json.dumps({
        "iterations": 16, "accepted": 5, "rejected": 10, "broken": 1,
        "broken_by_class": {"cosim_failed": 1},
        "baseline_fitness": 282.82, "final_fitness": 525.04,
        "best_fitness": 525.04, "best_round": 10, "delta_pct": 85.6,
        "best_lut4": 5453, "best_ff": 2138, "best_fmax_mhz": 220.22,
        "best_iterations": 10, "best_cycles": 4194377,
        "best_ipc_coremark": 2e-06,
    }))
    agent = tmp_path / "agent.log"
    agent.write_text("")
    summary = summarize_run(log, agent, provider="codex")
    assert summary["best_lut4"] == 5453
    assert summary["best_ff"] == 2138
    assert summary["best_fmax_mhz"] == 220.22
    assert summary["best_iterations"] == 10
    assert summary["best_cycles"] == 4194377
    assert summary["best_ipc_coremark"] == 2e-06


def test_summarize_run_missing_summary_includes_best_fpga_fields_none(tmp_path: Path):
    """The summary_missing row must still carry the FPGA-field keys (as None)
    so the results.jsonl schema is uniform across done/broken/missing rows."""
    summary = summarize_run(tmp_path / "absent.jsonl", tmp_path / "absent.log")
    assert summary.get("summary_missing") is True
    for k in ("best_lut4", "best_ff", "best_fmax_mhz",
              "best_iterations", "best_cycles", "best_ipc_coremark"):
        assert k in summary, f"missing key {k!r} in summary_missing row"
        assert summary[k] is None


# ---- clone_fixture: CoW copy fallback -----------------------------------


def _make_fixture_repo(path: Path, ref: str) -> None:
    """Minimal git repo `clone_fixture` can clone: a single commit on a
    branch named `ref` (mirrors the real bench-fixture-v1 / main ref)."""
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", "-b", ref], cwd=str(path),
                    check=True, capture_output=True)
    (path / "README.md").write_text("fixture\n")
    subprocess.run(["git", "add", "README.md"], cwd=str(path),
                    check=True, capture_output=True)
    subprocess.run(
        ["git", "-c", "user.email=t@t", "-c", "user.name=t",
         "commit", "--no-gpg-sign", "-q", "-m", "init"],
        cwd=str(path), check=True, capture_output=True,
    )


def test_clone_fixture_cow_fallback_cleans_partial_dest(tmp_path, monkeypatch):
    """If `cp -Rc` fails after partially creating rf_dest, the `cp -R`
    fallback must produce a flat copy of rf_src's contents directly under
    rf_dest -- not a nested rf_dest/<rf_src-basename>/... layout, which is
    what plain `cp -R` produces when its destination already exists."""
    ref = "bench-fixture-test"
    repo_root = tmp_path / "repo"
    _make_fixture_repo(repo_root, ref)

    rf_src = tmp_path / "rf_src"
    (rf_src / "cores" / "nerv").mkdir(parents=True)
    (rf_src / "cores" / "nerv" / "marker.txt").write_text("upstream")

    monkeypatch.setattr(runner, "find_riscv_formal", lambda: rf_src)

    real_run = subprocess.run

    def fake_run(cmd, *args, **kwargs):
        if len(cmd) >= 2 and cmd[0] == "cp" and cmd[1] == "-Rc":
            # Simulate clonefile(2) partially materializing the dest dir
            # before failing partway (e.g. cross-device copy).
            partial_dest = Path(cmd[-1])
            partial_dest.mkdir(parents=True, exist_ok=True)
            (partial_dest / "PARTIAL").write_text("partial cow copy")
            return subprocess.CompletedProcess(
                cmd, 1, stdout=b"", stderr=b"cp: clonefile failed")
        return real_run(cmd, *args, **kwargs)

    monkeypatch.setattr(subprocess, "run", fake_run)

    dest = tmp_path / "clone"
    clone_fixture(repo_root, ref, dest)

    rf_dest = dest / "formal" / "riscv-formal"
    # Correct flat layout: rf_dest/cores/nerv/marker.txt.
    assert (rf_dest / "cores" / "nerv" / "marker.txt").read_text() == "upstream"
    # Not nested under the source directory's basename.
    assert not (rf_dest / "rf_src").exists()
    # The partial CoW leftovers must be gone, not silently merged in.
    assert not (rf_dest / "PARTIAL").exists()


# ---- main(): disk preflight must measure clone_base, not REPO_ROOT ------


class _FakeStatvfs:
    def __init__(self, f_bavail, f_frsize):
        self.f_bavail = f_bavail
        self.f_frsize = f_frsize


def test_main_disk_preflight_measures_clone_base(tmp_path, monkeypatch):
    """Clones land under --clone-base, which can be a different volume
    than REPO_ROOT; the preflight gate must measure free space at
    clone_base, and must not crash via os.statvfs when clone_base
    doesn't exist yet (e.g. a fresh --clone-base override)."""
    monkeypatch.setattr(preflight, "missing_tools", lambda: [])

    seen = {}

    def fake_statvfs(path):
        seen["path"] = path
        if not Path(path).is_dir():
            raise FileNotFoundError(path)
        return _FakeStatvfs(f_bavail=250_000, f_frsize=4096)  # ~1 GB, below MIN_FREE_GB

    monkeypatch.setattr(os, "statvfs", fake_statvfs)

    clone_base = tmp_path / "does-not-exist-yet" / "clones"
    monkeypatch.setattr(
        sys, "argv", ["bench-runner", "--clone-base", str(clone_base)])

    rc = runner.main()

    assert rc == 2
    assert seen["path"] == str(clone_base)
    assert clone_base.is_dir()


# ---- run_one_job(): early-return paths must still leave forensics ------


def _stub_clone_fixture(monkeypatch):
    """Stand in for clone_fixture with something that just creates the
    destination directory, so these tests don't need a real git repo
    or a real riscv-formal checkout -- they're only exercising the
    early-return forensics paths, not the clone itself."""
    def fake_clone_fixture(repo_root, ref, dest):
        dest.mkdir(parents=True, exist_ok=True)
    monkeypatch.setattr(runner, "clone_fixture", fake_clone_fixture)


def test_run_one_job_fence_fail_preserves_forensics(tmp_path, monkeypatch):
    """A fence-install failure (install_opencode_config raising) must
    still leave a rep dir behind with env.json copied into it. Before
    the fix, this early return happened before out_dir was created and
    before the finalize copy of env.json, so the clone kept no rep-dir
    forensics at all -- and, having no rep dir, was never matched by
    gc's find_stale_clones, so orphan clones accumulated over a
    campaign."""
    _stub_clone_fixture(monkeypatch)

    def fake_install_opencode_config(clone):
        raise RuntimeError("boom")

    monkeypatch.setattr(runner, "install_opencode_config",
                        fake_install_opencode_config)

    model = ModelEntry(name="m0", model="prov/m0", provider="opencode")
    job = JobSpec(model=model, rep=1)
    results_dir = tmp_path / "results"

    row = run_one_job(
        job,
        repo_root=tmp_path / "repo",
        ref="main",
        clone_base=tmp_path / "clones",
        results_dir=results_dir,
        results_jsonl=results_dir / "results.jsonl",
        keys={},
        n=1, k=1, timeout_sec=1, max_cost_usd=1.0, keep_clone=False,
    )

    assert "fence install failed" in row["notes"]
    out_dir = results_dir / "m0" / "rep1"
    assert (out_dir / "env.json").is_file()


def test_run_one_job_missing_key_preserves_forensics(tmp_path, monkeypatch):
    """Same forensics requirement as the fence-fail case above, for the
    missing-API-key early return: env.json must land in the rep dir so
    the clone isn't an orphan invisible to gc's find_stale_clones."""
    _stub_clone_fixture(monkeypatch)
    monkeypatch.delenv("BENCH_TEST_MISSING_KEY_XYZ", raising=False)

    model = ModelEntry(name="m1", model="prov/m1", provider="codex",
                        key_env="BENCH_TEST_MISSING_KEY_XYZ")
    job = JobSpec(model=model, rep=1)
    results_dir = tmp_path / "results"

    row = run_one_job(
        job,
        repo_root=tmp_path / "repo",
        ref="main",
        clone_base=tmp_path / "clones",
        results_dir=results_dir,
        results_jsonl=results_dir / "results.jsonl",
        keys={},
        n=1, k=1, timeout_sec=1, max_cost_usd=1.0, keep_clone=False,
    )

    assert "missing API key env var BENCH_TEST_MISSING_KEY_XYZ" in row["notes"]
    out_dir = results_dir / "m1" / "rep1"
    assert (out_dir / "env.json").is_file()


# ---- main(): clone_base mkdir must fail the preflight cleanly ----------


def test_main_clone_base_mkdir_oserror_fails_cleanly(tmp_path, monkeypatch, capsys):
    """An unwritable clone-base parent must fail the preflight cleanly
    with a FATAL message and exit 2, not crash with an uncaught OSError
    traceback (the preflight block is supposed to be the clean-failure
    layer for exactly this kind of environment problem)."""
    monkeypatch.setattr(preflight, "missing_tools", lambda: [])

    clone_base = tmp_path / "clones"

    def fake_mkdir(self, *a, **kw):
        raise OSError(13, "Permission denied")

    monkeypatch.setattr(Path, "mkdir", fake_mkdir)
    monkeypatch.setattr(
        sys, "argv", ["bench-runner", "--clone-base", str(clone_base)])

    rc = runner.main()

    assert rc == 2
    captured = capsys.readouterr()
    assert "[bench] FATAL" in captured.err
    assert str(clone_base) in captured.err
    assert "Permission denied" in captured.err
