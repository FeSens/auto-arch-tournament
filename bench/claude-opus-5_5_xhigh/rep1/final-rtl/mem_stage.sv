// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register (or the posted store buffer below), and
// sign/zero-extends the loaded data into the MEM/WB register.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: shift the raw word right by `addr[1:0]*8`, then sign- or
//     zero-extend the low 8/16 bits per the LB/LBU/LH/LHU encoding.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Stall-only D-side. Two structures let the MEM-stage op complete on a
// cycle the dmem bus refuses (dmem_ready = 0). Neither is consulted when
// the bus serves the op. With dmem_ready tied to 1 (FPGA bench, formal
// wrapper) sb_valid_q has D = 0 and reset 0, so bus_free = mem_ready = 1,
// the dmem outputs are exactly the EX/MEM-derived values, ld_word =
// dmem_rdata, and every sb_* / dc_* / cand_* register drives only dead
// logic: synthesis removes all of it.
//
//   - Posted store buffer (1 entry). A store that finds the buffer empty
//     always completes (st_done): the bus writes it directly if it is
//     ready, otherwise {addr, replicated wdata, byte mask} are held in
//     sb_* and the store retires while the buffer retries the write.
//     The drain owns the bus (dmem outputs = sb_*, ren = 0) until it is
//     accepted; a MEM-stage op behind it waits unless it is a load that
//     hits the cache. One entry is FIFO, so memory (UART bytes, the
//     0x10000100/104 bench markers) sees stores in program order.
//
//   - Load cache: direct-mapped, one word per entry, index
//     addr[DC_TAG_LSB-1:2], tag addr[31:DC_TAG_LSB]. Filled by every bus
//     load, and updated by every store when it completes (merged into a
//     cached word or allocated as a full word; a partial store to an
//     uncached word invalidates the index). This core is the only dmem
//     master, so the cache always holds the architectural value. The
//     MMIO window (addr[28]) is never cached. A load that hits completes
//     on a refused cycle with the cached word.
//
//   The table is never read on a same-cycle path. It is read one cycle
//   ahead, keyed on the EX-stage address (ex_addr), into cand_hit_q /
//   cand_data_q, which are reloaded only on the edge EX/MEM takes that
//   instruction (ex_adv) and so describe the MEM-stage word. A MEM-stage
//   store or fill of the same word on that edge is bypassed into them.
//   While MEM holds, no cache update can complete (only the MEM-stage op
//   updates the cache, and it completes on the edge it leaves), so the
//   candidate stays exact.
//
// Misaligned (trapping) accesses keep their behavior: they wait for
// bus_free, never post and never fill.
//
// Late branch unit. A conditional BRANCH that read the rd of the LOAD
// directly ahead of it skipped the load-use stall (hazard_unit) and went
// through EX as an inert op (in.late). Both left ID/EX -> EX/MEM ->
// MEM/WB on the same edges (MEM/WB only holds for a memory op in EX/MEM,
// which a branch is not), so while the branch is in MEM the LOAD is in
// MEM/WB. The branch is resolved here from flops only: each operand is
// MEM/WB.read_data if it is the LOAD's rd (in.late_rs?), else the
// EX-forwarded EX/MEM.rs?_val, and a six-way compare gives the condition.
// The compare ends in a few flops, never in a 32-bit mux:
//   - late_kill_q: the branch mispredicted. It is the WB-stage redirect,
//     raised the cycle the branch is in MEM/WB. EX ORs it into redirect
//     (target late_tgt_q, the path IF did not take), so flush_if /
//     flush_id and the IF kill follow; EX/MEM captures a bubble, the
//     div_unit goes idle, and here the MEM-stage op (the wrong-path
//     instruction right behind the branch) is dropped: no dmem read or
//     write, no store post, no cache update, and MEM/WB captures it
//     with valid = reg_write = 0.
//   - MEM/WB.late_trap: taken to a misaligned target. It traps and falls
//     through; IF never predicts such a target, so it is no mispredict.
//   - the BHT update, as the cond-selected one of two counter values
//     precomputed from the carried fetch-time counter (with its write
//     enable skipped when the counter would not change). It wins the
//     shared BHT port over EX's write.
// RVFI takes the late branch's pc_wdata from late_tgt_q on a mispredict
// (core.sv); MEM/WB.pc_next holds the predicted next PC, selected here
// by flops. MEM/WB.rs?_val take the substituted operands.
//
// If the LOAD ahead trapped (misaligned: MEM/WB reg_write = 0), its rd
// keeps the old value, which the late path does not have (EX forwarded
// the LOAD's address instead). The branch is then replayed: it does not
// retire (MEM/WB valid = 0), writes no BHT, and late_kill_q redirects to
// its own pc, where it refetches with the LOAD retired.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, trap, plus rd_wdata via the loaded data;
//                 for a late branch rs1/rs2_rdata, trap and pc_wdata.
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
  // Cache lookahead key: the EX ALU result, which EX/MEM captures as the
  // load/store address on the edges ex_adv (= !stall_ex_mem) is high.
  // Only the word address [31:2] is used.
  input  logic [31:0]        ex_addr,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic               ex_adv,
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  input  logic               dmem_ready,
  // The MEM-stage memory op completes this cycle: via the bus, a cache
  // hit, or a store post. hazard_unit stalls on !mem_ready && mem op.
  output logic               mem_ready,
  // Late branch unit (registered): WB-stage redirect and its target
  output logic               late_kill,
  output logic [31:0]        late_tgt,
  // Late branch BHT update (registered, has priority over EX's)
  output logic                  bht_we,
  output logic [BHT_IDX_W-1:0]  bht_widx,
  output logic [1:0]            bht_wdata,
  // MEM/WB register output
  output mem_wb_t  out
);

  localparam int DC_IDX_W   = 10;                 // 1024 words
  localparam int DC_ENTRIES = 1 << DC_IDX_W;
  localparam int DC_TAG_LSB = DC_IDX_W + 2;       // tag = addr[31:12]
  localparam int DC_TAG_W   = 32 - DC_TAG_LSB;

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
  logic [31:0] load_data;

  // Misaligned mem-access trap. RV32I requires word-aligned LW/SW and
  // halfword-aligned LH/LHU/SH; byte ops are always aligned.
  // riscv-formal's RISCV_FORMAL_ALIGNED_MEM contract demands rvfi_trap=1
  // when the effective byte address is not aligned to the access width.
  // On trap, the dmem ports are gated off and ctrl propagates is_illegal.
  logic mem_misalign;
  logic mem_op;
  ctrl_t ctrl_with_trap;

  // Illegal-encoding decode. is_illegal only ever reaches rvfi_trap, so it
  // is decoded here from the registered EX/MEM instruction word instead
  // of in ID, where its cone (opcode/funct plus the full-word EBREAK
  // match) sat on the imem -> decode -> ID/EX path. EX/MEM.ctrl.is_illegal
  // arrives holding ID's opcode pre-check and EX's misaligned-target
  // trap. Only the decoder's is_illegal output is used; synthesis drops
  // the rest of this instance.
  logic dec_is_illegal;

  /* verilator lint_off PINCONNECTEMPTY */
  decoder u_ill_dec (
    .instr      (in.instr),
    .alu_op     (),
    .alu_src    (),
    .branch_op  (),
    .is_branch  (),
    .is_jump    (),
    .is_jalr    (),
    .is_lui     (),
    .is_auipc   (),
    .is_div     (),
    .mem_read   (),
    .mem_write  (),
    .mem_width  (),
    .mem_sext   (),
    .reg_write  (),
    .mem_to_reg (),
    .is_illegal (dec_is_illegal)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // Stall-only D-side (see header).
  logic        ld;          // aligned load in MEM
  logic        st;          // aligned store in MEM
  logic        cacheable;   // outside the MMIO window
  logic        bus_free;    // the bus serves the MEM-stage op this cycle
  logic        st_done;     // the MEM-stage store is written or posted
  logic        ld_fill;     // a bus load fills the cache
  logic [31:0] ld_word;     // the loaded word: bus, or cache on a hit
  logic [31:0] st_lanes;    // byte_mask expanded to bits
  logic [31:0] st_merged;   // cached word with the store's bytes merged
  logic        st_alloc;    // the store leaves its word cached

  logic        sb_valid_q;
  logic [31:0] sb_addr_q;
  logic [31:0] sb_wdata_q;
  logic [3:0]  sb_wmask_q;

  // dc_valid is reset; dc_tag / dc_data are resetless and never read
  // without it.
  logic [DC_ENTRIES-1:0] dc_valid;
  logic [DC_TAG_W-1:0]   dc_tag  [0:DC_ENTRIES-1];
  logic [31:0]           dc_data [0:DC_ENTRIES-1];

  logic [DC_IDX_W-1:0]   mem_idx;
  logic [DC_IDX_W-1:0]   look_idx;
  logic                  same_word;
  logic                  look_hit;
  logic                  cand_hit_q;
  logic [31:0]           cand_data_q;

  // MEM/WB register (declared here: the late branch unit reads the LOAD
  // it holds) and the late branch unit's flops.
  mem_wb_t               reg_q;
  logic                  late_kill_q;
  logic [31:0]           late_tgt_q;

  always_comb begin
    // Byte/halfword replication for stores.
    case (in.ctrl.mem_width)
      2'd0:    wdata_rep = {4{in.write_data[7:0]}};
      2'd1:    wdata_rep = {2{in.write_data[15:0]}};
      default: wdata_rep = in.write_data;
    endcase

    // Byte-lane mask shifted to addr[1:0] * 1.
    case (in.ctrl.mem_width)
      2'd0:    byte_mask = (4'b0001 << in.alu_result[1:0]);
      2'd1:    byte_mask = (4'b0011 << in.alu_result[1:0]);
      default: byte_mask = 4'b1111;
    endcase

    mem_op       = in.ctrl.mem_read || in.ctrl.mem_write;
    mem_misalign = mem_op && (
                     (in.ctrl.mem_width == 2'd2 && in.alu_result[1:0] != 2'b00) ||
                     (in.ctrl.mem_width == 2'd1 && in.alu_result[0]   != 1'b0)
                     // 2'd0 (byte) is never misaligned.
                   );

    ctrl_with_trap = in.ctrl;
    ctrl_with_trap.is_illegal = in.ctrl.is_illegal || dec_is_illegal
                             || mem_misalign;
    // A late-killed op never writes rd (and so is never forwarded).
    if (mem_misalign || late_kill_q)
      ctrl_with_trap.reg_write  = 1'b0;

    // A late-killed op is wrong-path: no bus access of any kind (its
    // address may be anything), no store post, no cache update.
    ld        = in.ctrl.mem_read  && !mem_misalign && !late_kill_q;
    st        = in.ctrl.mem_write && !mem_misalign && !late_kill_q;
    cacheable = !in.alu_result[28];
    bus_free  = dmem_ready && !sb_valid_q;
    st_done   = st && !sb_valid_q;
    ld_fill   = ld && bus_free && cacheable;
    mem_ready = bus_free || (ld && cand_hit_q) || st_done;
    ld_word   = bus_free ? dmem_rdata : cand_data_q;

    // dmem outputs: the buffered store while one is pending, else the
    // MEM-stage access (gated off on misalign). Register functions only,
    // never of dmem_ready.
    dmem_addr  = sb_valid_q ? sb_addr_q  : in.alu_result;
    dmem_wdata = sb_valid_q ? sb_wdata_q : wdata_rep;
    dmem_wen   = sb_valid_q ? sb_wmask_q : (st ? byte_mask : 4'b0000);
    dmem_ren   = ld && !sb_valid_q;

    // Load extraction: shift right then sign/zero-extend the low N bits.
    shifted   = ld_word >> (in.alu_result[1:0] * 8);
    byte_val  = shifted[7:0];
    hword_val = shifted[15:0];
    case (in.ctrl.mem_width)
      2'd0:    load_data = in.ctrl.mem_sext
                         ? {{24{byte_val[7]}},  byte_val}
                         : {24'b0,              byte_val};
      2'd1:    load_data = in.ctrl.mem_sext
                         ? {{16{hword_val[15]}}, hword_val}
                         : {16'b0,               hword_val};
      default: load_data = ld_word;
    endcase

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (mem_op && !mem_misalign)
                 ? {in.alu_result[31:2], 2'b00}
                 : 32'b0;

    // Cache store update: the stored bytes merged into the MEM-stage
    // word. It stays cached if it was (cand_hit_q) or the store covers
    // all of it.
    st_lanes  = {{8{byte_mask[3]}}, {8{byte_mask[2]}},
                 {8{byte_mask[1]}}, {8{byte_mask[0]}}};
    st_merged = (cand_data_q & ~st_lanes) | (wdata_rep & st_lanes);
    st_alloc  = cacheable && (cand_hit_q || byte_mask == 4'b1111);

    mem_idx   = in.alu_result[DC_TAG_LSB-1:2];
    look_idx  = ex_addr[DC_TAG_LSB-1:2];
    same_word = (in.alu_result[31:2] == ex_addr[31:2]);
    look_hit  = dc_valid[look_idx]
             && (dc_tag[look_idx] == ex_addr[31:DC_TAG_LSB])
             && !ex_addr[28];
  end

  // ── Posted store buffer ───────────────────────────────────────────────
  // Set when a store completes without the bus, cleared on the first
  // dmem_ready cycle (the drain has bus priority). The payload follows
  // the MEM stage while the buffer is empty and holds while it is full.
  always_ff @(posedge clock) begin
    if (reset) sb_valid_q <= 1'b0;
    else       sb_valid_q <= !dmem_ready && (sb_valid_q || st);
  end

  always_ff @(posedge clock) begin
    if (!sb_valid_q) begin
      sb_addr_q  <= in.alu_result;
      sb_wdata_q <= wdata_rep;
      sb_wmask_q <= byte_mask;
    end
  end

  // ── Load cache ────────────────────────────────────────────────────────
  // A same-edge update of look_idx for a different word is benign: the
  // read returns the pre-update entry and the tag check decides.
  always_ff @(posedge clock) begin
    if (st_done && st_alloc) begin
      dc_tag[mem_idx]  <= in.alu_result[31:DC_TAG_LSB];
      dc_data[mem_idx] <= st_merged;
    end else if (ld_fill) begin
      dc_tag[mem_idx]  <= in.alu_result[31:DC_TAG_LSB];
      dc_data[mem_idx] <= dmem_rdata;
    end
    if (ex_adv) begin
      cand_data_q <= (st_done && same_word) ? st_merged
                   : (ld_fill && same_word) ? dmem_rdata
                   :                          dc_data[look_idx];
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      dc_valid   <= '0;
      cand_hit_q <= 1'b0;
    end else begin
      if (st_done && cacheable) dc_valid[mem_idx] <= st_alloc;
      else if (ld_fill)         dc_valid[mem_idx] <= 1'b1;
      if (ex_adv) begin
        cand_hit_q <= (st_done && same_word) ? st_alloc
                    : (ld_fill && same_word) ? 1'b1
                    :                          look_hit;
      end
    end
  end

  // ── Late branch unit ──────────────────────────────────────────────────
  // Operands from flops only (see header). ld_trap: the LOAD in MEM/WB
  // did not write its rd (misaligned trap), so the branch is replayed.
  // late_redo / late_mis are only ever set with in.late, which EX/MEM
  // never holds on a late_kill cycle (the instruction right behind a
  // branch cannot be a late branch), so they need no kill term.
  logic        ld_trap;
  logic [31:0] late_a;
  logic [31:0] late_b;
  logic        late_cond;
  logic        late_redo;
  logic        late_mis;
  logic [1:0]  late_inc;
  logic [1:0]  late_dec;

  always_comb begin
    late_a = in.late_rs1 ? reg_q.read_data : in.rs1_val;
    late_b = in.late_rs2 ? reg_q.read_data : in.rs2_val;
    case (in.ctrl.branch_op)
      BR_BEQ:  late_cond = (late_a == late_b);
      BR_BNE:  late_cond = (late_a != late_b);
      BR_BLT:  late_cond = ($signed(late_a) <  $signed(late_b));
      BR_BGE:  late_cond = ($signed(late_a) >= $signed(late_b));
      BR_BLTU: late_cond = (late_a <  late_b);
      BR_BGEU: late_cond = (late_a >= late_b);
      default: late_cond = 1'b0;
    endcase
    ld_trap   = !reg_q.ctrl.reg_write;
    late_redo = in.late && ld_trap;
    // Architectural transfer: taken, and the target is aligned (pc is,
    // so branch_target[1] = imm[1]). IF predicted it in late_pred.
    late_mis  = in.late && (ld_trap
                || ((late_cond && !in.branch_target[1]) != in.late_pred));
    late_inc  = (in.bht_ctr == 2'b11) ? 2'b11 : in.bht_ctr + 2'd1;
    late_dec  = (in.bht_ctr == 2'b00) ? 2'b00 : in.bht_ctr - 2'd1;
  end

  logic                 late_bht_we_q;
  logic [BHT_IDX_W-1:0] late_bht_widx_q;
  logic [1:0]           late_bht_wdata_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      late_kill_q   <= 1'b0;
      late_bht_we_q <= 1'b0;
    end else begin
      late_kill_q   <= late_mis;
      late_bht_we_q <= in.late && !ld_trap
                    && (late_cond ? (in.bht_ctr != 2'b11) : (in.bht_ctr != 2'b00));
    end
    // Mispredicted: the path IF did not take (pc+4 = EX's pc_next for an
    // inert branch, or pc+imm). Replay: the branch itself.
    late_tgt_q       <= late_redo      ? in.pc
                      : in.late_pred   ? in.pc_next
                      :                  in.branch_target;
    late_bht_widx_q  <= in.pc[BHT_IDX_W+1:2];
    late_bht_wdata_q <= late_cond ? late_inc : late_dec;
  end

  assign late_kill = late_kill_q;
  assign late_tgt  = late_tgt_q;
  assign bht_we    = late_bht_we_q;
  assign bht_widx  = late_bht_widx_q;
  assign bht_wdata = late_bht_wdata_q;

  // ── MEM/WB register ───────────────────────────────────────────────────
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
      reg_q.alu_result <= in.alu_result;
      reg_q.read_data  <= load_data;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      // Late branch: the substituted operands, and the predicted next PC
      // (a mispredict's pc_wdata comes from late_tgt_q, see core.sv).
      reg_q.rs1_val    <= late_a;
      reg_q.rs2_val    <= late_b;
      reg_q.pc_next    <= (in.late && in.late_pred) ? in.branch_target
                                                    : in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= ld_word;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= (in.ctrl.mem_write && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.mem_rmask  <= (in.ctrl.mem_read  && !mem_misalign) ? byte_mask : 4'b0000;
      reg_q.ctrl       <= ctrl_with_trap;
      reg_q.instr      <= in.instr;
      reg_q.late_trap  <= in.late && late_cond && in.branch_target[1];
      reg_q.valid      <= in.valid && !late_kill_q && !late_redo;
    end
  end

  assign out = reg_q;

endmodule
