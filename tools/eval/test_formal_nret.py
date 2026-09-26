"""Tests for the nret-aware formal flow wiring."""
import pytest
from pathlib import Path

from tools.eval.formal import read_nret


def test_default_is_2_when_field_missing(tmp_path):
    yml = tmp_path / "core.yaml"
    yml.write_text("name: x\nisa: rv32im\n")
    assert read_nret(yml) == 2


def test_explicit_nret_1(tmp_path):
    yml = tmp_path / "core.yaml"
    yml.write_text("name: x\nnret: 1\n")
    assert read_nret(yml) == 1


def test_explicit_nret_2(tmp_path):
    yml = tmp_path / "core.yaml"
    yml.write_text("name: x\nnret: 2\n")
    assert read_nret(yml) == 2


def test_rejects_nret_3(tmp_path):
    yml = tmp_path / "core.yaml"
    yml.write_text("name: x\nnret: 3\n")
    with pytest.raises(ValueError, match="nret"):
        read_nret(yml)


def test_rejects_non_int_nret(tmp_path):
    yml = tmp_path / "core.yaml"
    yml.write_text("name: x\nnret: dual\n")
    with pytest.raises(ValueError, match="nret"):
        read_nret(yml)


def test_missing_file_defaults_to_2(tmp_path):
    # Some cores (legacy baseline) don't have core.yaml. Treat as default
    # rather than erroring — preserves backward compat.
    assert read_nret(tmp_path / "nonexistent.yaml") == 2


# --- _build_formal_env wiring ---

from tools.eval.formal import _build_formal_env


def _mk_core(tmp_path, name, nret=None):
    core_dir = tmp_path / "cores" / name
    core_dir.mkdir(parents=True)
    if nret is not None:
        (core_dir / "core.yaml").write_text(f"name: {name}\nnret: {nret}\n")
    return core_dir


def test_env_no_target_passes_through(tmp_path):
    env = _build_formal_env(tmp_path, target=None, base_env={"FOO": "bar"})
    assert env["FOO"] == "bar"
    assert "RTL_DIR" not in env
    assert "CORE_NAME" not in env
    assert "WRAPPER" not in env
    assert "CHECKS_CFG" not in env


def test_env_target_no_yaml_uses_defaults(tmp_path):
    _mk_core(tmp_path, "v1")  # no core.yaml
    env = _build_formal_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["CORE_NAME"] == "v1"
    # nret defaults to 2 → WRAPPER/CHECKS_CFG left unset so run_all.sh
    # falls back to wrapper.sv and checks.cfg (legacy behavior).
    assert "WRAPPER" not in env
    assert "CHECKS_CFG" not in env


def test_env_target_nret_2_uses_defaults(tmp_path):
    _mk_core(tmp_path, "v1", nret=2)
    env = _build_formal_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert "WRAPPER" not in env
    assert "CHECKS_CFG" not in env


def test_env_target_nret_1_selects_si_files(tmp_path):
    _mk_core(tmp_path, "v1", nret=1)
    env = _build_formal_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["CORE_NAME"] == "v1"
    assert env["WRAPPER"].endswith("formal/wrapper_si.sv")
    assert env["CHECKS_CFG"].endswith("formal/checks_si.cfg")
    # Paths must be absolute so run_all.sh resolves them regardless of cwd.
    assert Path(env["WRAPPER"]).is_absolute()
    assert Path(env["CHECKS_CFG"]).is_absolute()


# --- _build_synth_env (FPGA yosys env) ---

from tools.eval.fpga import _build_synth_env


def test_synth_env_no_target_passes_through(tmp_path):
    env = _build_synth_env(tmp_path, target=None, base_env={"FOO": "bar"})
    assert env["FOO"] == "bar"
    assert "RTL_DIR" not in env
    assert "GEN_DIR" not in env
    assert "BENCH" not in env


def test_synth_env_target_nret_2_omits_bench(tmp_path):
    _mk_core(tmp_path, "v1", nret=2)
    env = _build_synth_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["GEN_DIR"] == "cores/v1/generated"
    assert "BENCH" not in env  # synth.tcl falls back to fpga/core_bench.sv


def test_synth_env_target_no_yaml_omits_bench(tmp_path):
    _mk_core(tmp_path, "v1")
    env = _build_synth_env(tmp_path, target="v1", base_env={})
    assert "BENCH" not in env


def test_synth_env_target_nret_1_selects_si_bench(tmp_path):
    _mk_core(tmp_path, "v1", nret=1)
    env = _build_synth_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["GEN_DIR"] == "cores/v1/generated"
    assert env["BENCH"] == "fpga/core_bench_si.sv"


# --- _build_cosim_env (Verilator cosim build) ---

from tools.eval.cosim import _build_cosim_env


def test_cosim_env_no_target_passes_through(tmp_path):
    env = _build_cosim_env(tmp_path, target=None, base_env={"FOO": "bar"})
    assert env["FOO"] == "bar"
    assert "RTL_DIR" not in env
    assert "OBJ_DIR" not in env
    assert "NRET" not in env


def test_cosim_env_target_nret_2_uses_nret_2(tmp_path):
    _mk_core(tmp_path, "v1", nret=2)
    env = _build_cosim_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["OBJ_DIR"] == "cores/v1/obj_dir"
    assert env["NRET"] == "2"


def test_cosim_env_target_no_yaml_defaults_to_nret_2(tmp_path):
    _mk_core(tmp_path, "v1")
    env = _build_cosim_env(tmp_path, target="v1", base_env={})
    assert env["NRET"] == "2"


def test_cosim_env_target_nret_1_passes_nret_1(tmp_path):
    _mk_core(tmp_path, "v1", nret=1)
    env = _build_cosim_env(tmp_path, target="v1", base_env={})
    assert env["RTL_DIR"] == "cores/v1/rtl"
    assert env["OBJ_DIR"] == "cores/v1/obj_dir"
    assert env["NRET"] == "1"
