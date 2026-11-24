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
  // hold_wb: dmem stall is in effect. MEM/WB's data fields are RETAINED
  // (so the previously-retired LOAD's `rd` / `read_data` / `ctrl.reg_write`
  // remain visible to forward_unit), but `valid` is cleared so:
  //   - rvfi_order doesn't increment for held cycles
  //   - wb_stage doesn't write the regfile twice
  // Zeroing the whole register would lose the LOAD's load_data, breaking
  // MEM/WB->EX forwarding for any dependent instruction that's also held
  // in ID/EX during the stall (e.g. a BNE that consumes a LOAD's result).
  input  logic               hold_wb,
  input  ex_mem_t  in,
  input  logic [7:0]         lookup_index,
  input  logic               lookup_word,
  output logic [31:0]        predicted_value,
  output logic               load_hit,
  output logic               will_write,
  // dmem interface
  input  logic               dmem_ready,
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  // shifted[31:16] is dropped on byte/halfword loads; only [15:0] feeds
  // the sign/zero-extension mux.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] shifted;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  byte_val;
  logic [15:0] hword_val;
  logic [31:0] formatted_value;

  logic [31:0] mul_result;
  logic [31:0] div_magnitude, div_result;
  assign div_magnitude = divide_magnitude(in.div_completion);
  assign div_result = in.div_negate ? -div_magnitude : div_magnitude;
  multiplier u_mul (
    .op  (in.ctrl.alu_op),
    .a   (in.mul_rs1),
    .b   (in.write_data),
    .out (mul_result)
  );

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and ctrl propagates is_illegal.
  logic mem_misalign;
  logic mem_op;
  ctrl_t ctrl_with_trap;

  // One synchronous row holds the tag, raw word and last formatted load.
  // A word-width signature can never match a narrow load (SW and LW fill).
  // Bits 31:16 of an extended byte or halfword are all the saved sign.
  // Storing that bit once keeps the entire logical record in 64 bits.
  (* syn_ramstyle = "distributed_ram" *) logic [63:0] words [0:255];
  logic [255:0] occupied;
  logic [7:0] candidate_index, update_index;
  logic [9:0] candidate_tag;
  logic [4:0] signature, saved_signature;
  logic [31:0] saved_raw;
  logic [16:0] saved_value;
  logic [63:0] lookup_row;
  logic candidate_valid, update, install;
  logic word_hit, word_width, refresh, format_matches;
  logic [31:0] raw_word, row_word;

  assign update_index = in.effective_addr[9:2];
  assign word_width = in.ctrl.mem_width[1];
  assign signature = {in.ctrl.mem_width, in.ctrl.mem_sext, in.effective_addr[1:0]};
  assign word_hit = in.ctrl.mem_read && !mem_misalign && candidate_valid &&
                    {12'b0, candidate_tag, candidate_index} == in.effective_addr[31:2];
  // Check the redundant bytes of the row in parallel with address verification.
  // A disagreement uses the normal refresh/replay path. Lane comparisons
  // need neither the bus response nor the output of the MEM formatter.
  (* syn_keep = 1 *) logic [3:0] low_byte_matches;
  (* syn_keep = 1 *) logic [1:0] high_byte_matches;
  logic upper_matches, sign_matches;
  for (genvar lane = 0; lane < 4; lane++) begin : gen_low_byte_match
    assign low_byte_matches[lane] = saved_value[7:0] == saved_raw[8*lane +: 8];
  end
  for (genvar halfword = 0; halfword < 2; halfword++) begin : gen_high_byte_match
    assign high_byte_matches[halfword] = saved_value[15:8] == saved_raw[16*halfword+8 +: 8];
  end
  assign upper_matches = in.ctrl.mem_width[0] ? high_byte_matches[in.effective_addr[1]]
                                             : saved_value[15:8] == {8{saved_value[16]}};
  assign sign_matches = saved_value[16] == (in.ctrl.mem_sext &&
                                     (in.ctrl.mem_width[0] ? saved_value[15] : saved_value[7]));
  assign format_matches = saved_signature == signature && low_byte_matches[in.effective_addr[1:0]]
                       && upper_matches && sign_matches;
  assign load_hit = word_hit && (word_width || format_matches);
  assign lookup_row = words[lookup_index];
  assign raw_word = word_hit ? saved_raw : dmem_rdata;
  assign row_word = in.ctrl.mem_write ? in.write_data : raw_word;

  // Every accepted RAM store changes the row. Narrow stores invalidate
  // it because the bus supplies only the bytes being written.
  // A signature miss completes internally, including when the bus is stalled.
  assign refresh = word_hit && !load_hit;
  assign update = !reset && (refresh || (in.effective_addr[31:20] == 0 && dmem_ready &&
                             !mem_misalign && (dmem_ren || in.ctrl.mem_write)));
  assign install = in.ctrl.mem_read || word_width;
  always_ff @(posedge clock) begin
    if (!hold_wb) begin
      {candidate_tag, saved_signature, saved_raw, saved_value} <= lookup_row;
      // Sample the producer's width with the row so its consumer sees
      // a registered candidate at the input to the one-hot bypass.
      predicted_value <= lookup_word ? lookup_row[48:17] : {{16{lookup_row[16]}}, lookup_row[15:0]};
    end
    if (update && install)
      words[update_index] <= {in.effective_addr[19:10], signature, row_word, formatted_value[16:0]};
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      occupied <= '0;
      candidate_valid <= 1'b0;
    end else begin
      if (update) occupied[update_index] <= install;
      if (!hold_wb) begin
        candidate_index <= lookup_index;
        candidate_valid <= occupied[lookup_index] && !(update && update_index == lookup_index);
      end
    end
  end

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{in.write_data[7:0]}};
      2'd1:    wdata_rep = {2{in.write_data[15:0]}};
      default: wdata_rep = in.write_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.effective_addr[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.effective_addr[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    ctrl_with_trap = in.ctrl;
    if (mem_misalign) begin
      ctrl_with_trap.is_illegal = 1'b1;
      ctrl_with_trap.reg_write  = 1'b0;
    end

    // Combinational dmem outputs — gated off on misalign.
    dmem_addr  = in.effective_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;

    // Load extraction: shift right then sign/zero-extend the low N bits.
    shifted   = row_word >> (in.effective_addr[1:0] * 8);
    byte_val  = shifted[7:0];
    hword_val = shifted[15:0];
    // Upper sign bits are identical for every stored format, so synthesis
    // can share them in the RAM. A word-width signature ignores this field.
    if (in.ctrl.mem_width[0])
      formatted_value = {{16{in.ctrl.mem_sext && hword_val[15]}}, hword_val};
    else
      formatted_value = {{24{in.ctrl.mem_sext && byte_val[7]}}, byte_val};

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.effective_addr[31:2], 2'b00}
                 : 32'b0;
  end

  assign mem_op = in.ctrl.mem_read || in.ctrl.mem_write;
  assign will_write = ctrl_with_trap.reg_write;
  assign mem_misalign = mem_op && ((in.ctrl.mem_width == 2'd2 && in.effective_addr[1:0] != 0) ||
                                   (in.ctrl.mem_width == 2'd1 && in.effective_addr[0]));
  assign dmem_ren = in.ctrl.mem_read && !mem_misalign && !word_hit;

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
      reg_q.alu_result <= is_mul(in.ctrl.alu_op) ? mul_result :
                          in.div_valid ? div_result : in.alu_result;
      reg_q.read_data  <= load_hit ? predicted_value : (word_width ? dmem_rdata : formatted_value);
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      // RVFI reports both encoded register fields, even immediate bits.
      // An unused field can advance on a miss and take its value here.
      reg_q.rs1_val    <= in.rs1_trace_load && reg_q.ctrl.reg_write ? reg_q.read_data : in.rs1_val;
      reg_q.rs2_val    <= in.rs2_trace_load && reg_q.ctrl.reg_write ? reg_q.read_data : in.rs2_val;
      reg_q.pc_next    <= in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= raw_word;
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
