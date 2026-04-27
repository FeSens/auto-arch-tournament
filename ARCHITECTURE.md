# Architecture — 5-stage in-order RV32IM

This is the day-one microarchitecture. Caches, branch prediction, scoreboards,
and multi-issue are *research-loop hypotheses*, not part of the baseline.

## Pipeline

```
   ┌────┐  ┌────┐  ┌────┐  ┌─────┐  ┌────┐
   │ IF │→│ ID │→│ EX │→│ MEM │→│ WB │
   └────┘  └────┘  └────┘  └─────┘  └────┘
      │       │       ▲
      │       └───────┤    (forward EX→ID, MEM→ID)
      │               │
      └─── stall ←────┘    (load-use hazard, 1 cycle)
```

Five named pipeline registers: `IF/ID`, `ID/EX`, `EX/MEM`, `MEM/WB`. Every
register is an explicit `always_ff @(posedge clock) if (reset) … else …`
block — no `initial` blocks anywhere in synthesizable RTL.

## Per-stage contract

| Stage | Module           | Job                                                                                          |
|-------|------------------|----------------------------------------------------------------------------------------------|
| IF    | `if_stage.sv`    | PC reg, default `+4`, redirected by EX on taken-branch / JAL / JALR. Bubble (`NOP=0x13`) on flush. |
| ID    | `id_stage.sv`    | `decoder` + `imm_gen`, regfile read, ID/EX latch.                                            |
| EX    | `ex_stage.sv`    | ALU, branch resolve + redirect target, EX/MEM latch. Forwarding muxes for rs1/rs2.           |
| MEM   | `mem_stage.sv`   | Byte-lane mask + replicated wdata, sign-/zero-extended load. MEM/WB latch.                   |
| WB    | `wb_stage.sv`    | Regfile write mux (ALU vs loaded data).                                                      |

## Combinational submodules

| Module             | Purpose                                                                                    |
|--------------------|--------------------------------------------------------------------------------------------|
| `core_pkg.sv`      | `package core_pkg`: AluOp/BranchOp `localparam`s + pipeline `typedef struct` bundles + RVFIPort. |
| `decoder.sv`       | Maps 32-bit instruction → control bundle. **Default `isIllegal = 1`**, cleared only inside validated opcode/funct arms. |
| `alu.sv`           | RV32IM ALU. Hardware `signed *` / `signed /` operators, with explicit handling for div-by-0 (returns `-1`) and `INT_MIN/-1` (returns `INT_MIN`). |
| `imm_gen.sv`       | I/S/B/U/J immediate sign-extension.                                                        |
| `reg_file.sv`      | 32×32, x0 hardwired, write-first bypass.                                                   |
| `hazard_unit.sv`   | Load-use detect → 1-cycle stall on `IF/ID`+`ID/EX`, NOP into EX.                           |
| `forward_unit.sv`  | Two 2-bit selects from EX/MEM rd and MEM/WB rd into the ALU operand muxes.                 |

## Top-level (`core.sv`)

- Wires the five stages.
- Owns the `rvfi_order` counter (32-bit, increments on `rvfi_valid`).
- Latches MEM/WB → RVFI in a single explicit register (no per-stage RVFI plumbing).
- `rvfi_trap = isIllegal_at_retirement`. EBREAK is *not* trapping in this
  project's convention (it's the test-harness termination marker); ECALL,
  CSR ops, and MRET *are* trapping.

## SoC (`soc.sv`)

- imem: `logic [31:0] mem [0:8191]` (32 KiB).
- dmem: `logic [31:0] mem [0:8191]` (32 KiB).
- UART: 9600 baud, MMIO at `0x1000_0000` (TX-only data) and bench markers at
  `0x1000_0100` / `0x1000_0104` (CoreMark `start_time` / `stop_time`).
- All RAM declarations carry a vendor-portable `(* ram_style = "block" *)`
  attribute (and the Gowin equivalent in synth scripts) so BRAM inference is
  deterministic across Yosys / Verilator.

## RVFI

The RVFI port lives at top-level only. Stages do not see RVFI. The MEM/WB
register has every field needed and `core.sv` wires them through. Field
exact set: see `core_pkg.sv::RVFIPort`. Wrapper at `formal/wrapper.sv`
binds these by name.

## Why no caches / predictor on day one

The orchestrator's first job is to prove the eval pipeline grades any
hypothesis correctly. A featureless baseline maximizes headroom for the
research loop and minimizes places where an early bug can hide.
Hypotheses that add a 2-bit BHT, an L0 instruction buffer, or an early
branch resolve in ID are exactly the kind of changes the loop should
discover and accept.
