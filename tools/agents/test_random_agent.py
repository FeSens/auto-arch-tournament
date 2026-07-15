"""Tests for the random-mutation control agent."""
import random
from pathlib import Path

from tools.agents import random_agent as ra

SV = """\
module alu(input logic [31:0] a, b, output logic [31:0] y);
  // adder path
  assign y = (a == 32'h0000_0001) ? a + b : a & b;
endmodule
"""


def _mk_worktree(tmp_path: Path) -> Path:
    rtl = tmp_path / "cores" / "bench" / "rtl"
    rtl.mkdir(parents=True)
    (rtl / "alu.sv").write_text(SV)
    return tmp_path


def test_candidates_skip_comment_lines():
    cands = ra.line_candidates("  // adder path + fast")
    assert cands == []


def test_op_swap_produces_parseable_line():
    cands = ra.line_candidates("  assign y = a + b;")
    assert any("a - b" in c.new_line for c in cands)


def test_eq_swap_guards_composites():
    cands = ra.line_candidates("  assign t = (a == b) && c;")
    assert any("!=" in c.new_line for c in cands)
    assert all("&" * 3 not in c.new_line for c in cands)


def test_ternary_swap_swaps_arms():
    line = "  assign y = sel ? a + b : a & b;"
    cands = [c for c in ra.line_candidates(line) if c.kind == "ternary_swap"]
    assert len(cands) == 1
    assert "? a & b : a + b" in cands[0].new_line


def test_lit_perturb_xors_low_bit():
    line = "  assign y = 32'h0000_0001;"
    cands = [c for c in ra.line_candidates(line) if c.kind == "lit_perturb"]
    assert len(cands) == 1
    assert "32'h0" in cands[0].new_line and "_0001" not in cands[0].new_line


def test_mutate_deterministic(tmp_path):
    wt1 = _mk_worktree(tmp_path / "a")
    wt2 = _mk_worktree(tmp_path / "b")
    rng1 = random.Random("101:hyp-x")
    rng2 = random.Random("101:hyp-x")
    m1 = ra.apply_mutations(wt1, "bench", rng1, k=2)
    m2 = ra.apply_mutations(wt2, "bench", rng2, k=2)
    assert [str(m) for m in m1] == [str(m) for m in m2]
    assert (wt1 / "cores/bench/rtl/alu.sv").read_text() == \
           (wt2 / "cores/bench/rtl/alu.sv").read_text()


def test_mutate_touches_only_rtl(tmp_path):
    wt = _mk_worktree(tmp_path)
    (wt / "Makefile").write_text("all:\n")
    before = (wt / "Makefile").read_text()
    ra.apply_mutations(wt, "bench", random.Random(1), k=3)
    assert (wt / "Makefile").read_text() == before


def test_verilator_absent_applies_no_mutations(tmp_path, monkeypatch):
    wt = _mk_worktree(tmp_path)
    monkeypatch.setattr("shutil.which", lambda *a, **kw: None)
    monkeypatch.setenv("RANDOM_AGENT_SEED", "101")
    monkeypatch.chdir(wt)
    ra._implement(
        "TARGET CORE: cores/bench/ "
        "Edit, create, or delete files in the worktree. "
        "Hypothesis: hyp-20260101-001-r1s0"
    )
    assert (wt / "cores/bench/rtl/alu.sv").read_text() == SV
    notes = (wt / "cores/bench/implementation_notes.md").read_text()
    assert "INVALID" in notes
