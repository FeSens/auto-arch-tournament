# Random-mutation control on harness 2.8.4 (amendment 15 part A, amendment 16)

| run | seed | slots | accepted | rejected (passed every gate) | broken: formal | broken: cosim | other | final CoreMark | held-out |
|---|---|---|---|---|---|---|---|---|---|
| rep1 | 101 | 45 | 0 | 2 | 38 | 5 | 0 | 12.12 | 309 |
| rep2 | 102 | 45 | 0 | 1 | 41 | 3 | 0 | 12.12 | 309 |
| rep3 | 103 | 45 | 0 | 3 | 38 | 4 | 0 | 12.12 | 309 |
| all | | 135 | 0 | 6 | 117 | 12 | 0 | | |

Mutation records: 135 of 135 slots; distinct seed materials 135; distinct edit sets 132; all lint-clean: True.
k (mutations per slot): {1: 37, 2: 50, 3: 48}; draws used: {1: 102, 2: 24, 3: 5, 4: 2, 5: 2}.
Operators: {'lit_perturb': 177, 'op_swap': 90, 'ternary_swap': 14}. Files: {'decoder.sv': 124, 'alu.sv': 41, 'ex_stage.sv': 24, 'forward_unit.sv': 19, 'mem_stage.sv': 17, 'core.sv': 16, 'core_pkg.sv': 15, 'reg_file.sv': 9, 'if_stage.sv': 6, 'imm_gen.sv': 5, 'wb_stage.sv': 4, 'hazard_unit.sv': 1}.
First failing formal check: {'insn_add_ch0': 34, 'insn_beq_ch0': 12, 'insn_jal_ch0': 10, 'ill_ch0': 6, 'insn_lb_ch0': 6, 'insn_addi_ch0': 5, 'insn_jalr_ch0': 4, 'insn_sb_ch0': 4} ...

## Slots that passed formal

| run | slot | gate | CoreMark | mutations (formal-blind ones marked *) |
|---|---|---|---|---|
| rep1 | r3s0 | regression | 12.12 | decoder.sv:57 lit_perturb `is_lui     = 1'b0;` -> `is_lui     = 1'b1;` |
| rep1 | r6s1 | regression | 12.12 | core_pkg.sv:99 op_swap (comment only) `logic [31:0] write_data;     // raw rs2 (post-forw` -> `logic [31:0] write_data;     // raw rs2 (post+forw` |
| rep1 | r6s2 | cosim_failed |  | decoder.sv:223 lit_perturb `7'b1110011: begin` -> `7'b1110010: begin` |
| rep1 | r9s1 | cosim_failed |  | alu.sv:84 op_swap* `ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a /` -> `ALU_DIVU: out = (b != 32'b0) ? 32'hFFFFFFFF : (a /` |
| rep1 | r10s0 | cosim_failed |  | alu.sv:79 op_swap* `else if (a == 32'h80000000 && b == 32'hFFFFFFFF)` -> `else if (a == 32'h80000000 && b != 32'hFFFFFFFF)`; mem_stage.sv:147 lit_perturb `reg_q.mem_rmask  <= (in.ctrl.mem_read  && !mem_mis` -> `reg_q.mem_rmask  <= (in.ctrl.mem_read  && !mem_mis` |
| rep1 | r14s1 | cosim_failed |  | alu.sv:84 lit_perturb* `ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a /` -> `ALU_DIVU: out = (b == 32'b0) ? 32'hfffffffe : (a /` |
| rep1 | r15s1 | cosim_failed |  | core.sv:145 op_swap (comment only) `.fwd_mem_wb      (wb_w_data),            // WB-sta` -> `.fwd_mem_wb      (wb_w_data),            // WB+sta`; core.sv:225 lit_perturb `io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA` -> `io_rvfi_ixl_0       = 2'd0;     // 32-bit ISA` |
| rep2 | r1s1 | cosim_failed |  | imm_gen.sv:21 lit_perturb `7'b0000011, 7'b0010011, 7'b1100111, 7'b1110011:` -> `7'b0000011, 7'b0010011, 7'b1100111, 7'b1110010:`; alu.sv:40 lit_perturb* `mul_uu = {32'b0, a} * {32'b0, b};` -> `mul_uu = {32'b0, a} * {32'b1, b};`; if_stage.sv:53 lit_perturb `out.instr = (flush || redirect) ? 32'h0000_0013 : ` -> `out.instr = (flush || redirect) ? 32'h12 : imem_da` |
| rep2 | r5s0 | regression | 12.12 | decoder.sv:152 lit_perturb `3'd2:       mem_width = 2'd2;` -> `3'd3:       mem_width = 2'd2;` |
| rep2 | r7s2 | cosim_failed |  | core.sv:225 lit_perturb `io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA` -> `io_rvfi_ixl_0       = 2'd0;     // 32-bit ISA` |
| rep2 | r8s0 | cosim_failed |  | alu.sv:89 lit_perturb* `out = 32'b0;` -> `out = 32'b1;` |
| rep3 | r4s1 | cosim_failed |  | alu.sv:84 op_swap* `ALU_DIVU: out = (b == 32'b0) ? 32'hFFFFFFFF : (a /` -> `ALU_DIVU: out = (b != 32'b0) ? 32'hFFFFFFFF : (a /` |
| rep3 | r4s2 | regression | 12.05 | decoder.sv:170 lit_perturb `default: mem_width = 2'd2;` -> `default: mem_width = 2'd3;` |
| rep3 | r6s2 | cosim_failed |  | core.sv:225 lit_perturb `io_rvfi_ixl_0       = 2'd1;     // 32-bit ISA` -> `io_rvfi_ixl_0       = 2'd0;     // 32-bit ISA` |
| rep3 | r8s2 | regression | 11.85 | core_pkg.sv:28 lit_perturb `localparam logic [4:0] ALU_SLL    = 5'd7;` -> `localparam logic [4:0] ALU_SLL    = 5'd6;`; core_pkg.sv:27 lit_perturb `localparam logic [4:0] ALU_SLTU   = 5'd6;` -> `localparam logic [4:0] ALU_SLTU   = 5'd7;` |
| rep3 | r10s2 | cosim_failed |  | alu.sv:93 op_swap* `ALU_REMU: out = (b == 32'b0) ? a : (a % b);` -> `ALU_REMU: out = (b != 32'b0) ? a : (a % b);` |
| rep3 | r13s1 | cosim_failed |  | alu.sv:93 lit_perturb* `ALU_REMU: out = (b == 32'b0) ? a : (a % b);` -> `ALU_REMU: out = (b == 32'b1) ? a : (a % b);` |
| rep3 | r14s0 | regression | 12.12 | core_pkg.sv:126 op_swap (comment only) `logic [31:0] mem_wdata;      // replicated byte-la` -> `logic [31:0] mem_wdata;      // replicated byte+la` |

8 of the 18 formal-passing slots contain a mutation in the real multiplier/divider path that formal (ALTOPS) never sees.
Cosim caught 12 formal-passing slots: 8 with a formal-blind mutation, 4 without (their edits are in the table).
17 of 281 mutations edit only a trailing comment; 2 slots are comment-only edits (no RTL change), outcomes {'regression': 2}.
