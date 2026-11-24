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
  // A blocked request retains the preceding WB writer for collection.
  // Clearing valid lets it retire exactly once.
  output logic               hold_wb,
  input  logic [31:0]        ex_addr,
  input  logic               dmem_ready,
  input  logic               early_hit, retry_hit,
  input  logic [31:0]        early_word, retry_word,
  output logic               reference,
  output logic [3:0]         ref_mask,
  output logic [31:0]        ref_data,
  input  logic [31:0]        div_result,
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
  output logic [31:0]        wb_value,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  logic [31:0] raw_word;
  logic [31:0] load_data;

  assign wb_value = ({32{in.use_mul_high}} & in.mul_high) |
                    ({32{in.use_div}} & div_result) |
                    ({32{in.ctrl.mem_to_reg && !early_hit}} & load_data) |
                    ({32{in.use_alu_result || (in.ctrl.mem_to_reg && early_hit)}} & in.alu_result);

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

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = (in.ctrl.mem_read || in.ctrl.mem_write)
                 ? {in.mem_addr[31:2], 2'b00}
                 : 32'b0;
  end

  wire ram = in.ram_access;
  wire load_op = in.ctrl.mem_read;
  wire store_op = in.ctrl.mem_write;
  wire demand = load_op && !(early_hit || retry_hit);
  wire postable = store_op && ram;
  wire ordered = in.valid && in.serialize;
  logic posted;
  logic [31:0] posted_data;
  logic [3:0] posted_mask;

  // When empty, the registered MEM operation owns the bus. A RAM store
  // can complete even on a wait cycle. A full slot drains and refills
  // on one edge, retaining priority over every external read and MMIO.
  wire enqueue = postable && !hold_wb && (posted || !dmem_ready);
  // A single registered bus address also serves as the slot address.
  // On drain, restore a waiting demand address before enabling its read.
  always_ff @(posedge clock)
    if (!posted || dmem_ready)
      dmem_addr <= (enqueue || hold_wb) ? in.mem_addr : ex_addr;
  assign dmem_wdata = posted ? posted_data : wdata_rep;
  assign dmem_wen   = posted ? posted_mask : (store_op ? byte_mask : 4'b0);
  assign dmem_ren   = !posted && demand;
  assign hold_wb    = ((demand || (store_op && !ram)) && (posted || !dmem_ready)) ||
                      (posted && (ordered || (postable && !dmem_ready)));
  always_ff @(posedge clock) begin
    if (reset) posted <= 1'b0;
    else if (enqueue) begin
      posted <= 1'b1;
      posted_data <= wdata_rep;
      posted_mask <= byte_mask;
    end else if (dmem_ready) posted <= 1'b0;
  end

  assign reference = ram && (load_op || store_op) && !hold_wb;
  assign ref_mask = store_op ? byte_mask : {4{demand}};
  assign ref_data = store_op ? wdata_rep : dmem_rdata;
  wire [31:0] corrected_word = retry_hit ? retry_word : dmem_rdata;
  assign raw_word = early_hit ? early_word : corrected_word;
  // Select bytes and the extension bit in parallel on the RAM return
  // path. For an aligned access the first byte always comes from addr.
  wire half_load = in.ctrl.mem_width == 1;
  wire word_load = in.ctrl.mem_width == 2;
  wire [3:0] first_lane = 4'b0001 << in.mem_addr[1:0];
  wire [3:0] byte_sign_lane = first_lane & {4{in.ctrl.mem_width == 0 && in.ctrl.mem_sext}};
  wire [3:0] sign_bits = {corrected_word[31], corrected_word[23], corrected_word[15], corrected_word[7]};
  wire byte_sign = |(byte_sign_lane & sign_bits);
  wire half_sign = half_load && in.ctrl.mem_sext &&
                   (in.mem_addr[1] ? corrected_word[31] : corrected_word[15]);
  assign load_data[7:0] = ({8{first_lane[0]}} & corrected_word[7:0]) |
                          ({8{first_lane[1]}} & corrected_word[15:8]) |
                          ({8{first_lane[2]}} & corrected_word[23:16]) |
                          ({8{first_lane[3]}} & corrected_word[31:24]);
  assign load_data[15:8] = {8{byte_sign}} |
                           ({8{word_load || (half_load && !in.mem_addr[1])}} & corrected_word[15:8]) |
                           ({8{half_load && in.mem_addr[1]}} & corrected_word[31:24]);
  assign load_data[31:16] = {16{byte_sign || half_sign}} | ({16{word_load}} & corrected_word[31:16]);

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.wb_value   <= wb_value;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.rs1_val;
      reg_q.rs2_val    <= in.rs2_val;
      reg_q.pc_next    <= in.pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= raw_word;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= store_op ? byte_mask : 4'b0000;
      reg_q.mem_rmask  <= load_op ? byte_mask : 4'b0000;
      reg_q.ctrl       <= in.ctrl;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
