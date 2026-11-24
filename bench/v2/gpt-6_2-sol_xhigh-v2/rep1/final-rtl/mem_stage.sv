// rtl/mem_stage.sv
//
// Memory access stage. Drives the dmem read/write ports combinationally
// from the EX/MEM register. Formats the response for EX forwarding
// and captures the selected result in MEM/WB.
//
// Byte-lane discipline:
//   - Write data is replicated across all four byte lanes; the
//     byte-mask (mem_wmask) selects the actual destination bytes.
//   - Load: select each response byte and the extension bit in parallel.
//   - For RVFI ALIGNED_MEM, mem_addr is reported word-aligned and the
//     byte position is captured in mem_rmask / mem_wmask.
//
// Latency:        1 cycle (MEM/WB register clocked here).
// RVFI fields:    feeds mem_addr, mem_rmask, mem_wmask, mem_rdata,
//                 mem_wdata, plus rd_wdata via the loaded-data path.
module mem_stage (
  input  logic               clock,
  input  logic               reset,
  input  logic               hold_wb,
  input  logic [31:0]        pc_next,
  input  logic               control_misalign,
  // Some fields in the EX control bundle are unused after EX.
  /* verilator lint_off UNUSEDSIGNAL */
  input  ex_mem_t  in,
  /* verilator lint_on UNUSEDSIGNAL */
  // dmem interface
  output logic [31:0]        dmem_addr,
  output logic [31:0]        dmem_wdata,
  input  logic [31:0]        dmem_rdata,
  input  logic               dmem_ready,
  output logic [3:0]         dmem_wen,
  output logic               dmem_ren,
  output logic               mem_request,
  output logic               write_en,
  input  logic               load_rs1,
  input  logic               load_rs2,
  input  logic               load_address_rs1,
  output logic               load_word,
  output logic [31:0]        load_address_data,
  output logic [31:0]        load_data_rs1,
  output logic [31:0]        load_data_rs2,
  // MEM/WB register output
  output mem_wb_t  out
);

  logic [31:0] wdata_rep;
  logic [3:0]  byte_mask;
  logic [31:0] aligned_addr;
  logic [31:0] load_data;

  assign mem_request = (in.ctrl.mem_read || in.ctrl.mem_write) && !in.mem_misalign;
  assign write_en = in.ctrl.reg_write && !in.mem_misalign;
  assign load_word = in.ctrl.mem_width == 2'd2;
  // load_address_rs1 already includes the qualified youngest writer match.
  assign load_address_data = {32{load_address_rs1 && load_word && dmem_ready}} & dmem_rdata;

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

    // Combinational dmem outputs — gated off on misalign.
    dmem_addr  = in.effective_addr;
    dmem_wdata = wdata_rep;
    dmem_wen   = (in.ctrl.mem_write && !in.mem_misalign) ? byte_mask : 4'b0000;
    dmem_ren   = in.ctrl.mem_read && !in.mem_misalign;

    // RVFI ALIGNED_MEM expects word-aligned mem_addr; mem_addr=0 if no access.
    aligned_addr = mem_request ? {in.effective_addr[31:2], 2'b00} : 32'b0;
  end

  // Qualify the lane masks before they meet the data RAM response, so each
  // formatted load can feed its operand's one-hot bypass directly.
  function automatic logic [31:0] format_load(
    input logic [31:0]  data,
    input load_format_t format,
    input logic         select_load
  );
    logic [3:0] signs;
    load_format_t mask;
    begin
      signs = {data[31], data[23], data[15], data[7]};
      mask = select_load ? format : '0;
      format_load[7:0] = ({8{mask.low_bytes[0]}} & data[7:0])
                       | ({8{mask.low_bytes[1]}} & data[15:8])
                       | ({8{mask.low_bytes[2]}} & data[23:16])
                       | ({8{mask.low_bytes[3]}} & data[31:24]);
      format_load[14:8] = ({7{mask.mid_bytes[0]}} & data[14:8])
                        | ({7{mask.mid_bytes[1]}} & data[30:24])
                        | {7{|(mask.mid_sign & signs)}};
      format_load[15] = |(mask.bit15 & signs);
      format_load[30:16] = ({15{mask.high_half}} & data[30:16])
                         | {15{|(mask.high_sign & signs)}};
      format_load[31] = |(mask.bit31 & signs);
    end
  endfunction

  assign load_data_rs1 = format_load(dmem_rdata, in.load_format, load_rs1);
  assign load_data_rs2 = format_load(dmem_rdata, in.load_format, load_rs2);
  assign load_data = format_load(dmem_rdata, in.load_format, in.result_sel.load);

  // ── MEM/WB register ───────────────────────────────────────────────────
  mem_wb_t reg_q;

  always_ff @(posedge clock) begin
    if (reset) begin
      reg_q <= '0;
    end else if (hold_wb) begin
      // Keep the result and writer qualification available to the
      // stalled consumer after the producer retires.
      reg_q.valid <= 1'b0;
    end else begin
      reg_q.pc         <= in.pc;
      reg_q.result     <= ({32{in.result_sel.other}} & in.other_result)
                        | ({32{in.result_sel.add}}   & in.add_result)
                        | ({32{in.result_sel.shift}} & in.shift_result)
                        | ({32{in.result_sel.div}}   & in.div_result)
                        | ({32{in.result_sel.mul}}   & in.mul_result)
                        | load_data;
      reg_q.rd         <= in.rd;
      reg_q.rs1_addr   <= in.rs1_addr;
      reg_q.rs2_addr   <= in.rs2_addr;
      reg_q.rs1_val    <= in.rs1_val;
      reg_q.rs2_val    <= in.rs2_val;
      reg_q.pc_next    <= pc_next;
      reg_q.mem_addr   <= aligned_addr;
      reg_q.mem_rdata  <= dmem_rdata;
      reg_q.mem_wdata  <= wdata_rep;
      reg_q.mem_wmask  <= dmem_wen;
      reg_q.mem_rmask  <= dmem_ren ? byte_mask : 4'b0000;
      reg_q.reg_write  <= write_en;
      reg_q.trap       <= in.ctrl.is_illegal || in.mem_misalign || control_misalign;
      reg_q.instr      <= in.instr;
      reg_q.valid      <= in.valid;
    end
  end

  assign out = reg_q;

endmodule
