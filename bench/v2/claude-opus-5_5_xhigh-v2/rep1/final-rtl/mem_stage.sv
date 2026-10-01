// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register, and sign/zero-extends the loaded data into
// the MEM/WB register.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: flat byte-lane AND-OR (result byte 0 from a 4:1 byte mux,
//     byte 1 / [31:16] from their rdata lane or the sign fill), selects
//     pre-decoded in EX from agu_sum[1:0] and the LB/LBU/LH/LHU/LW code.
//   - MUL*: alu_result is 0; the EX/MEM product register's selected half
//     is ORed in here (alu_or_mul -> forward + MEM/WB.alu_result).
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, plus rd_wdata via the loaded-data path.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // hold_wb: dmem stall is in effect. MEM/WB's data fields are RETAINED
  // (so the previously-retired LOAD's `rd` / `read_data` / `ctrl.reg_write`
  // remain visible to forward_unit), but `valid` is cleared so:
  //   - rvfi_order doesn't increment for held cycles
  //   - wb_stage doesn't write the regfile twice
  // Zeroing the whole register would lose the LOAD's load_data, breaking
  // MEM/WB->EX forwarding for any dependent instruction that's also held
  // in ID/EX during the stall (e.g. a BNE that consumes a LOAD's result).
  input  logic               hold_wb,
  // ex_mem_t carries branch_taken / branch_target / pc_next / rs?_val
  // for downstream RVFI use; mem_stage only consumes a subset, so the
  // remaining fields look unused from this module's perspective.
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  // ID bypass source: this stage's write-back value and its trap-cleared
  // write enable (a misaligned load writes nothing).
  // EX/MEM product register (ex_stage) and the split forward sources:
  // fwd_data is the non-load value (alu_or_mul), load_data the load
  // value; ID picks load_data at its last mux level when mem_to_reg.
  input  logic [63:0]        mul_p,
  output logic [31:0]        fwd_data,
  output logic [31:0]        load_data,
  output logic               fwd_w_en,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  logic [7:0]  ld_byte0;
  logic        ld_sign;
  logic [31:0] alu_or_mul;

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and ctrl propagates is_illegal.
  logic mem_misalign;
  logic mem_op;
  ctrl_t ctrl_with_trap;

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{in.write_data[7:0]}};
      2'd1:    wdata_rep = {2{in.write_data[15:0]}};
      default: wdata_rep = in.write_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.mem_addr[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.mem_addr[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    mem_op       = in.ctrl.mem_read || in.ctrl.mem_write;
    mem_misalign = mem_op && (
                     (in.ctrl.mem_width == 2'd2 && in.mem_addr[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && in.mem_addr[0]   != 1'b0)
                     // 2'd0 (byte) is never misaligned.
                   );

    ctrl_with_trap = in.ctrl;
    if (mem_misalign) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end

    // Combinational dmem outputs — gated off on misalign.
    // AGU lane: EX/MEM.mem_addr (rs1 + imm) is the only address source.
    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read  && !mem_misalign;

    // Load extraction: flat AND-OR of rdata byte lanes plus the sign
    // fill, every select pre-decoded in EX (agu_sum[1:0], width, sext).
    case (in.ld_b0_idx)
      2'd0:    ld_byte0 = dmem_rdata[7:0];
      2'd1:    ld_byte0 = dmem_rdata[15:8];
      2'd2:    ld_byte0 = dmem_rdata[23:16];
      default: ld_byte0 = dmem_rdata[31:24];
    endcase
    case (in.ld_sgn_idx)
      2'd0:    ld_sign = dmem_rdata[7];
      2'd1:    ld_sign = dmem_rdata[15];
      2'd2:    ld_sign = dmem_rdata[23];
      default: ld_sign = dmem_rdata[31];
    endcase
    load_data[7:0]   = ld_byte0;
    load_data[15:8]  = ({8{in.ld_b1_lo}}             & dmem_rdata[15:8])
                     | ({8{in.ld_b1_hi}}             & dmem_rdata[31:24])
                     | ({8{in.ld_sx_b1 && ld_sign}});
    load_data[31:16] = ({16{in.ld_hi_word}}          & dmem_rdata[31:16])
                     | ({16{in.ld_sx_hi && ld_sign}});

    // Non-load result: MUL* have alu_result = 0 and one product half
    // selected; every other op has both product selects 0.
    alu_or_mul = in.alu_result
               | ({32{in.sel_mul_lo}} & mul_p[31:0])
               | ({32{in.sel_mul_hi}} & mul_p[63:32]);

    fwd_data = alu_or_mul;
    fwd_w_en = ctrl_with_trap.reg_write;

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // Clear valid (no double-retire / no double-regfile-write), but
      // KEEP every other field. Forwarding from MEM/WB to a stalled
      // dependent in ID/EX needs the held LOAD's rd/read_data/ctrl
      // alive for as many cycles as the dmem stall lasts.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.alu_result <= alu_or_mul;
      reg_q.read_data  <= load_data;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.rs1_val;
      reg_q.rs2_val    <= in.rs2_val;
      reg_q.pc_next    <= in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.mem_rmask  <= (in.ctrl.mem_read  && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.ctrl       <= ctrl_with_trap;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
