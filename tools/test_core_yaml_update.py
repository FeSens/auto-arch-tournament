"""core.yaml auto-update: after a successful fpga eval, current: section
reflects the latest measured fitness."""
from pathlib import Path
import yaml


def test_update_current_writes_yaml(tmp_path):
    # Setup a minimal core.yaml.
    core_dir = tmp_path / "cores" / "v1"
    core_dir.mkdir(parents=True)
    (core_dir / "core.yaml").write_text(
        "name: v1\nisa: rv32im\ntarget_fpga: x\n"
        "targets:\n  fmax_mhz: 90\ncurrent: {}\n"
    )

    from tools.orchestrator import update_core_yaml_current
    update_core_yaml_current(
        target="v1", repo_root=tmp_path,
        fmax_mhz=78.4, lut4=2647, ff=1834,
        coremark_iter_s=312.6,
        source_id="hyp-test-001",
    )

    y = yaml.safe_load((core_dir / "core.yaml").read_text())
    assert y["current"]["fmax_mhz"] == 78.4
    assert y["current"]["lut4"] == 2647
    assert y["current"]["coremark_per_mhz"] == round(312.6 / 78.4, 4)
    assert y["current"]["source_id"] == "hyp-test-001"
    assert "updated" in y["current"]
