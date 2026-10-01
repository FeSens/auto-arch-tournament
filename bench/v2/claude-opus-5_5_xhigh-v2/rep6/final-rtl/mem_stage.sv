// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register (address = the dedicated AGU field
// EX/MEM.mem_addr), forms the MUL* product from the EX/MEM-latched
// operands and the merged regfile write data (load / mul / alu).
//
// The merged result is MEM's only data output into the pipeline: it is
// the ID bypass source for the instruction in MEM (exported as its
// non-load half and the ungated load data, so id_stage can put the late
// DO-derived load data in the last AND-OR into ID/EX.rs?_val / b_val)
// and the D of the small
// write-port register w_q = MEM/WB.{w_en, rd, result}, which writes the
// regfile one cycle later (the late DO-derived net never fans out to the
// regfile words). MEM/WB is no EX forward source, so its data fields load
// every cycle; only w_en / valid / upd_we see the dmem stall. The other
// MEM/WB fields are RVFI-only (retirement = the cycle after MEM).
//
// Misaligned accesses were already turned into traps in EX (mem_read /
// mem_write cleared, is_illegal set), so no trap logic lives here.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: the raw word's byte lanes are AND-OR selected by one-hot
//     lane / sign-fill selects registered in EX (EX/MEM.ld_*, decoded
//     from addr[1:0], width and sext), so no address / width decode sits
//     behind the dmem DO.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, plus rd_wdata via MEM/WB.result.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  // stall: dmem stall is in effect (EX/MEM holds the LOAD/STORE). MEM has
  // not completed: MEM/WB.valid / w_en and upd_we are cleared, so
  //   - rvfi_order doesn't increment for held cycles
  //   - the regfile is not written (the held instruction writes on the
  //     cycle the bus delivers)
  input  logic               stall,
  input  ex_mem_t  in,
  // result of the instruction in MEM (ID bypass source), in two halves
  // that are never both nonzero: result = nl_result | ld_data
  output logic [31:0]        nl_result,   // mul | add_q | oth_q (0 for loads)
  output logic [31:0]        ld_data,     // aligned / extended load data (0 unless LOAD)
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  // MEM/WB register output
  output mem_wb_t  out,
  // fetch_pred write port (registered here, written in the WB cycle)
  output logic               upd_we,
  output logic [5:0]         upd_idx,
  output logic [20:0]        upd_data     // {v, ctr, tag, off}
);

  // ── Predictor training, from EX/MEM flops only ────────────────────────
  // The branch outcome is recomputed here on the post-forward operands
  // EX/MEM already latches (MUL operands), so no EX net gains a consumer.
  //   taken          : {1, tm ? sat_inc(ctr) : 2'b10, tag, off}
  //   not taken, tm  : {1, sat_dec(ctr), tag, off}
  //   p_bad, no B/J  : v = 0
  logic        t_eq;
  logic        t_lt;
  logic        t_taken;
  logic [1:0]  t_inc;
  logic [1:0]  t_dec;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [32:0] t_diff;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        upd_we_d;
  logic [20:0] upd_data_d;

  always_comb begin
    t_eq    = in.rs1_val == in.rs2_val;
    t_diff  = {in.rs1_val[31] & ~in.br_uns, in.rs1_val}
            - {in.rs2_val[31] & ~in.br_uns, in.rs2_val};
    t_lt    = t_diff[32];
    t_taken = in.tr_jal || ((in.br_use_lt ? t_lt : t_eq) ^ in.br_inv);
    t_inc   = (in.pk_ctr == 2'b11) ? 2'b11 : in.pk_ctr + 2'd1;
    t_dec   = (in.pk_ctr == 2'b00) ? 2'b00 : in.pk_ctr - 2'd1;

    upd_we_d   = 1'b0;
    upd_data_d = {1'b1, 2'b10, in.pk_idx[9:6], in.tr_off};
    if (in.tr_br || in.tr_jal) begin
      if (t_taken) begin
        upd_we_d        = 1'b1;
        upd_data_d[19:18] = in.pk_tm ? t_inc : 2'b10;
      end else if (in.pk_tm) begin
        upd_we_d        = 1'b1;
        upd_data_d[19:18] = t_dec;
      end
    end else if (in.tr_bad) begin
      upd_we_d   = 1'b1;
      upd_data_d = 21'b0;
    end
    upd_we_d = upd_we_d && in.valid;
  end

  logic        upd_we_q;
  logic [5:0]  upd_idx_q;
  logic [20:0] upd_data_q;

  always_ff @(posedge clock) begin
    if (reset)      upd_we_q <= 1'b0;
    else if (stall) upd_we_q <= 1'b0;
    else            upd_we_q <= upd_we_d;
  end

  always_ff @(posedge clock) begin
    upd_idx_q  <= in.pk_idx[5:0];
    upd_data_q <= upd_data_d;
  end

  assign upd_we   = upd_we_q;
  assign upd_idx  = upd_idx_q;
  assign upd_data = upd_data_q;

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  logic        ld_sign;
  logic [31:0] load_data;
  logic [31:0] mul_result;
  logic [31:0] result;
  logic        mem_op;

  mul_unit u_mul (
    .op     (in.ctrl.alu_op),
    .ax     (in.mul_ax),
    .bx     (in.mul_bx),
    .sel_lo (in.sel_mlo),
    .sel_hi (in.sel_mhi),
    .a      (in.rs1_val),
    .b      (in.rs2_val),
    .out    (mul_result)
  );

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

    mem_op     = in.ctrl.mem_read || in.ctrl.mem_write;

    dmem_addr  = in.mem_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = in.ctrl.mem_write ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read;

    // Load extraction: AND-OR of DO bits on the registered one-hot lane
    // selects (EX/MEM.ld_*, all 0 unless LOAD, so load_data is 0 then).
    ld_sign = |(in.ld_s & {dmem_rdata[31], dmem_rdata[23],
                           dmem_rdata[15], dmem_rdata[7]});
    load_data[7:0]   = ({8{in.ld_b[0]}} & dmem_rdata[7:0])
                     | ({8{in.ld_b[1]}} & dmem_rdata[15:8])
                     | ({8{in.ld_b[2]}} & dmem_rdata[23:16])
                     | ({8{in.ld_b[3]}} & dmem_rdata[31:24]);
    load_data[15:8]  = ({8{in.ld_h0}} & dmem_rdata[15:8])
                     | ({8{in.ld_h2}} & dmem_rdata[31:24])
                     | {8{in.ld_hx & ld_sign}};
    load_data[31:16] = ({16{in.ld_w}} & dmem_rdata[31:16])
                     | {16{in.ld_wx & ld_sign}};

    // Merged regfile write data: one-hot AND-OR on registered selects
    // (mul_result is already gated by sel_mlo / sel_mhi in mul_unit,
    // load_data by the ld_* lanes, and the two ALU halves are 0 for loads
    // and MUL*).
    result = mul_result | load_data | in.add_q | in.oth_q;

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = mem_op ? {in.mem_addr[31:2], 2'b00} : 32'b0;
  end

  assign nl_result = mul_result | in.add_q | in.oth_q;
  assign ld_data   = load_data;

  // ── MEM/WB register (w_q write port + RVFI retirement) ────────────────
  // valid / w_en: reset, cleared while MEM is stalled. Data fields: no
  // reset, no enable (don't-care unless valid / w_en).
  mem_wb_t reg_q;
  logic    valid_q;
  logic    w_en_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      valid_q <= 1'b0;
      w_en_q  <= 1'b0;
    end else begin
      valid_q <= in.valid && !stall;
      w_en_q  <= in.w_ok  && !stall;
    end
  end

  always_ff @(posedge clock) begin
    reg_q.pc         <= in.pc;
    reg_q.result     <= result;
    reg_q.w_en       <= 1'b0;   // overridden by w_en_q
    reg_q.rd         <= in.rd;
    reg_q.rs1_addr   <= in.rs1_addr;
    reg_q.rs2_addr   <= in.rs2_addr;
    reg_q.rs1_val    <= in.rs1_val;
    reg_q.rs2_val    <= in.rs2_val;
    reg_q.pc_next    <= in.pc_next;
    reg_q.mem_addr   <= aligned_addr;
    reg_q.mem_rdata  <= dmem_rdata;
    reg_q.mem_wdata  <= wdata_rep;
    reg_q.mem_wmask  <= in.ctrl.mem_write ? byte_mask : 4'b0000;
    reg_q.mem_rmask  <= in.ctrl.mem_read  ? byte_mask : 4'b0000;
    reg_q.ctrl       <= in.ctrl;
    reg_q.instr      <= in.instr;
    reg_q.valid      <= 1'b0;   // overridden by valid_q
  end

  always_comb begin
    out       = reg_q;
    out.valid = valid_q;
    out.w_en  = w_en_q;
  end

endmodule
