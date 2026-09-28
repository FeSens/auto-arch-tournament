"""Hypothesis agents work in their own disposable worktree (harness 2.3,
incident 02): an in-place trial edit is neither visible in the shared clone
(to sibling agents or their before/after checks) nor left behind, and the
YAML still reaches the round's hypotheses directory."""
import subprocess
from pathlib import Path

import tools.agents.hypothesis as h

V0 = "module core; endmodule\n"


def _repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    (repo / "cores/bench/rtl").mkdir(parents=True)
    (repo / "cores/bench/rtl/core.sv").write_text(V0)
    (repo / "cores/bench/experiments/hypotheses").mkdir(parents=True)
    (repo / "cores/bench/experiments/hypotheses/.gitkeep").touch()
    (repo / ".gitignore").write_text("cores/*/worktrees/\n")
    g = ["git", "-C", str(repo), "-c", "user.email=t@t", "-c", "user.name=t"]
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(g + ["add", "-A"], check=True)
    subprocess.run(g + ["commit", "-q", "--no-gpg-sign", "-m", "v0"], check=True)
    return repo


def test_trial_edits_stay_in_the_agents_own_workspace(tmp_path, monkeypatch):
    repo = _repo(tmp_path)
    monkeypatch.chdir(repo)
    monkeypatch.setattr(h, "_build_prompt", lambda *a, **k: "p")
    seen = {}

    def agent(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        ws = Path(cwd)
        seen["cwd"] = ws
        # An in-place trial experiment, deliberately left behind.
        (ws / "cores/bench/rtl/core.sv").write_text("module core; wire trial; endmodule\n")
        seen["shared_rtl_during"] = (repo / "cores/bench/rtl/core.sv").read_text()
        (ws / "cores/bench/experiments/hypotheses/hyp-x-r1s0.yaml").write_text("id: hyp-x-r1s0\n")
        return 0, False

    monkeypatch.setattr(h, "run_agent_streaming", agent)
    path = h.run_hypothesis_agent([], 1.0, 1.0, hyp_id="hyp-x-r1s0",
                                  allowed_yaml_ids=["hyp-x-r1s0"], target="bench")
    assert seen["cwd"].resolve() != repo.resolve()
    assert seen["shared_rtl_during"] == V0                 # siblings never see the trial
    assert (repo / "cores/bench/rtl/core.sv").read_text() == V0
    assert Path(path).parent == (repo / "cores/bench/experiments/hypotheses").resolve()
    assert "hyp-x-r1s0" in Path(path).read_text()
    assert not seen["cwd"].exists()                          # workspace discarded


def test_main_clone_writes_are_still_rejected(tmp_path, monkeypatch):
    repo = _repo(tmp_path)
    monkeypatch.chdir(repo)
    monkeypatch.setattr(h, "_build_prompt", lambda *a, **k: "p")

    def agent(cmd, cwd, log_path, timeout_sec, mode="w", provider=None):
        (repo / "cores/bench/rtl/core.sv").write_text("tampered\n")   # absolute path
        (Path(cwd) / "cores/bench/experiments/hypotheses/hyp-x-r1s0.yaml").write_text("id: x\n")
        return 0, False

    monkeypatch.setattr(h, "run_agent_streaming", agent)
    try:
        h.run_hypothesis_agent([], 1.0, 1.0, hyp_id="hyp-x-r1s0",
                               allowed_yaml_ids=["hyp-x-r1s0"], target="bench")
        raise AssertionError("expected PermissionError")
    except PermissionError as e:
        assert "cores/bench/rtl/core.sv" in str(e)
    assert (repo / "cores/bench/rtl/core.sv").read_text() == V0   # rolled back
