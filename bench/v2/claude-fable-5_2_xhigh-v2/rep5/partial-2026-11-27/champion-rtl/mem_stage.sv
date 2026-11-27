// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register, and sign/zero-extends the loaded data into
// the MEM/WB register.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: shift the raw word right by `addr[1:0]*8`, then sign- or
//     zero-extend the low 8/16 bits per the LB/LBU/LH/LHU encoding.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, plus rd_wdata via the loaded-data path.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // hold_wb: dmem stall is in effect. `valid` is cleared so:
  //   - rvfi_order doesn't increment for held cycles
  //   - wb_stage doesn't write the regfile twice
  // The data fields are don't-care in such a cycle (MEM/WB.rd_val feeds
  // only the regfile; forwarding of this stage's value happens in ID).
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
  // reg_write the instruction in MEM will carry into MEM/WB (after the
  // misaligned-access trap gate) — used by ID to pre-qualify forwarding.
  output logic               reg_write_next,
  // Combinational load result (valid when the bus is ready): ID bypasses
  // it into the ID/EX operand registers (MEM -> ID capture bypass).
  output logic [31:0]        load_data_o,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  logic [31:0] load_data;

  // Load extraction as a flat one-hot AND-OR. Every select below is a
  // function of EX/MEM flops only (width / sext / addr[1:0]); the late
  // dmem read data only passes the AND-OR (it also feeds the ID/EX
  // operand registers through the MEM -> ID capture bypass).
  logic       ld_b, ld_h, ld_w;
  logic [3:0] q_lo  /* synthesis syn_keep = 1 */;  // [7:0]  <- rdata byte k
  logic [1:0] q_mid /* synthesis syn_keep = 1 */;  // [15:8] <- rdata byte 1 / 3
  logic       q_hi  /* synthesis syn_keep = 1 */;  // [31:16] <- rdata (word)
  logic [3:0] s_mid /* synthesis syn_keep = 1 */;  // sign of byte k -> [15:8]
  logic [3:0] s_hi  /* synthesis syn_keep = 1 */;  // sign of byte k -> [31:16]
  logic       sign_mid;
  logic       sign_hi;

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
    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read  && !mem_misalign;

    // Load extraction: byte k = addr[1:0] (LB/LBU), halfword addr[1]
    // (LH/LHU; addr[0] = 1 traps, value is don't-care), word = raw data.
    ld_b = (in.ctrl.mem_width == 2'd0);
    ld_h = (in.ctrl.mem_width == 2'd1);
    ld_w = !(ld_b || ld_h);

    q_lo[0]  = ld_w || (ld_h && !in.mem_addr[1]) || (ld_b && in.mem_addr[1:0] == 2'd0);
    q_lo[1]  = ld_b && in.mem_addr[1:0] == 2'd1;
    q_lo[2]  = (ld_h && in.mem_addr[1]) || (ld_b && in.mem_addr[1:0] == 2'd2);
    q_lo[3]  = ld_b && in.mem_addr[1:0] == 2'd3;

    q_mid[0] = ld_w || (ld_h && !in.mem_addr[1]);
    q_mid[1] = ld_h && in.mem_addr[1];
    q_hi     = ld_w;

    // Sign sources: byte loads extend bit 7 of byte k into [31:8],
    // halfword loads bit 15 of the half into [31:16].
    for (int k = 0; k < 4; k++)
      s_mid[k] = in.ctrl.mem_sext && ld_b && (in.mem_addr[1:0] == 2'(k));
    s_hi    = s_mid;
    s_hi[1] = s_mid[1] || (in.ctrl.mem_sext && ld_h && !in.mem_addr[1]);
    s_hi[3] = s_mid[3] || (in.ctrl.mem_sext && ld_h &&  in.mem_addr[1]);

    sign_mid = (s_mid[0] & dmem_rdata[7])  | (s_mid[1] & dmem_rdata[15])
             | (s_mid[2] & dmem_rdata[23]) | (s_mid[3] & dmem_rdata[31]);
    sign_hi  = (s_hi[0]  & dmem_rdata[7])  | (s_hi[1]  & dmem_rdata[15])
             | (s_hi[2]  & dmem_rdata[23]) | (s_hi[3]  & dmem_rdata[31]);

    load_data[7:0]   = ({8{q_lo[0]}} & dmem_rdata[7:0])
                     | ({8{q_lo[1]}} & dmem_rdata[15:8])
                     | ({8{q_lo[2]}} & dmem_rdata[23:16])
                     | ({8{q_lo[3]}} & dmem_rdata[31:24]);
    load_data[15:8]  = ({8{q_mid[0]}} & dmem_rdata[15:8])
                     | ({8{q_mid[1]}} & dmem_rdata[31:24])
                     | {8{sign_mid}};
    load_data[31:16] = ({16{q_hi}} & dmem_rdata[31:16])
                     | {16{sign_hi}};

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  assign reg_write_next = ctrl_with_trap.reg_write;
  assign load_data_o    = load_data;

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else begin
      // No data retention on a dmem stall: nothing forwards from MEM/WB
      // any more (ID bypasses the MEM value into ID/EX at capture), so a
      // held cycle only has to clear `valid` (no double-retire / no
      // double regfile write; w_en = reg_write && valid).
      reg_q.pc         <= in.pc;
      reg_q.rd_val     <= in.ctrl.mem_to_reg ? load_data : in.alu_result;
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
      reg_q.valid      <= in.valid && !hold_wb;
    end
  end

  assign out = reg_q;

endmodule
