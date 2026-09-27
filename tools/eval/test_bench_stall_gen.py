"""fpga/bench_stall_gen.sv must reproduce test/cosim/main.cpp's bus
backpressure cycle for cycle (HWE Bench V2: the timed netlist and the
simulated circuit see the same stalls).

The reference below is a transcription of main.cpp's bus_accepts_main():
xorshift32 seeded 0xDEADBEEF, one draw for imem then one for dmem per
cycle, accept when (state & 0x7F) < 100. The test builds the module with
Verilator and compares 100,000 cycles.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
TOOLCHAIN_BIN = REPO / ".toolchain" / "oss-cad-suite" / "bin"
N_CYCLES = 100_000

TB = """
module tb;
  logic clock = 0, reset = 0, imem_ready, dmem_ready;
  bench_stall_gen dut(.clock, .reset, .imem_ready, .dmem_ready);
  integer i;
  initial begin
    #1 reset = 1; #1 reset = 0;
    for (i = 0; i < %d; i++) begin
      $display("%%0d%%0d", imem_ready, dmem_ready);
      #1 clock = 1; #1 clock = 0;
    end
    $finish;
  end
endmodule
"""


def reference(n: int) -> list[str]:
    mask = 0xFFFFFFFF
    s = 0xDEADBEEF

    def draw() -> int:
        nonlocal s
        s ^= (s << 13) & mask
        s ^= s >> 17
        s ^= (s << 5) & mask
        s &= mask
        return int((s & 0x7F) < 100)

    out = []
    for _ in range(n):
        i = draw()
        d = draw()
        out.append(f"{i}{d}")
    return out


def _verilator() -> str | None:
    cand = TOOLCHAIN_BIN / "verilator"
    return str(cand) if cand.exists() else shutil.which("verilator")


def test_reference_matches_main_cpp_constants():
    # Guard against the C++ model drifting away from this transcription.
    src = (REPO / "test" / "cosim" / "main.cpp").read_text()
    assert "0xDEADBEEFu" in src
    assert "(lfsr_state_main & 0x7Fu) < 100u" in src
    assert "top->io_imemReady = istall ? bus_accepts_main() : 1;" in src
    assert "top->io_dmemReady = dstall ? bus_accepts_main() : 1;" in src


def test_hardware_sequence_matches_simulation(tmp_path):
    verilator = _verilator()
    if verilator is None:
        pytest.skip("verilator not available")
    (tmp_path / "tb.sv").write_text(TB % N_CYCLES)
    build = subprocess.run(
        [verilator, "--binary", "--timing", "-Wno-fatal", "--top-module", "tb",
         "-Mdir", str(tmp_path / "obj"),
         str(REPO / "fpga" / "bench_stall_gen.sv"), str(tmp_path / "tb.sv")],
        capture_output=True, text=True,
    )
    assert build.returncode == 0, build.stderr[-2000:]
    run = subprocess.run([str(tmp_path / "obj" / "Vtb")],
                         capture_output=True, text=True, timeout=300)
    got = [l.strip() for l in run.stdout.splitlines() if l.strip() in ("00", "01", "10", "11")]
    want = reference(N_CYCLES)
    assert len(got) == N_CYCLES
    first_bad = next((k for k, (g, w) in enumerate(zip(got, want)) if g != w), None)
    assert first_bad is None, f"cycle {first_bad}: hw={got[first_bad]} sim={want[first_bad]}"
    # Sanity: roughly 100/128 accept rate on each port.
    for port in (0, 1):
        rate = sum(int(x[port]) for x in got) / N_CYCLES
        assert 0.76 < rate < 0.80
