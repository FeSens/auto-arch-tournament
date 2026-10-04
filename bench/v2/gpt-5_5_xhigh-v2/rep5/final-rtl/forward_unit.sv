// rtl/forward_unit.sv
//
// Registered operand forwarding tags. For each rs in the ID/EX source list,
// precompute where the freshest value will live on the cycle that payload is
// allowed into EX1:
//   00 (NONE)    : ID/EX register's rs?_val (= regfile read of one cycle ago)
//   01 (EX_MEM)  : the registered EX2/MEM ALU result (not LOAD data)
//   10 (MEM_WB)  : the WB-stage's regfile-write data
//
// The unit looks one clock edge ahead: an EX1 ALU producer that is about to
// advance becomes EX/MEM, and an EX/MEM producer that is about to advance
// becomes MEM/WB. ID-stage holds still recompute the tags each cycle, so
// load-use and long-stall cases pick up the value as soon as it becomes
// forwardable.
//
// Latency:        1 cycle, in lockstep with the ID/EX register.
// RVFI fields:    n/a — feeds rs1_rdata / rs2_rdata via EX-stage muxes.
module forward_unit (
  input  logic       clock,
  input  logic       reset,
  input  logic       id_next_valid,
  input  logic [4:0] id_next_rs1,
  input  logic [4:0] id_next_rs2,
  input  logic [4:0] ex1_rd,
  input  logic       ex1_w_en,
  input  logic       ex1_mem_read,
  input  logic       ex1_advances,
  input  logic [4:0] ex_mem_rd,
  input  logic       ex_mem_w_en,
  input  logic       ex_mem_mem_read,
  input  logic       ex_mem_advances,
  input  logic [4:0] mem_wb_rd,
  input  logic       mem_wb_w_en,
  input  logic       mem_wb_stays,
  output logic [1:0] fwd_rs1,
  output logic [1:0] fwd_rs2
);

  localparam logic [1:0] FWD_NONE   = 2'd0;
  localparam logic [1:0] FWD_EX_MEM = 2'd1;
  localparam logic [1:0] FWD_MEM_WB = 2'd2;

  logic [1:0] fwd_rs1_next;
  logic [1:0] fwd_rs2_next;

  // Younger writers block older matches even when the younger result is not
  // forwardable yet; the hazard unit will keep ID/EX out of EX1 until this
  // registered tag is recomputed with an available source.
  always_comb begin
    fwd_rs1_next = FWD_NONE;
    if (id_next_valid && id_next_rs1 != 5'b0) begin
      if (ex1_w_en && ex1_rd == id_next_rs1) begin
        if (ex1_advances && !ex1_mem_read) fwd_rs1_next = FWD_EX_MEM;
      end else if (ex_mem_w_en && ex_mem_rd == id_next_rs1) begin
        if (ex_mem_advances) fwd_rs1_next = FWD_MEM_WB;
      end else if (mem_wb_stays && mem_wb_w_en && mem_wb_rd == id_next_rs1) begin
        fwd_rs1_next = FWD_MEM_WB;
      end
    end
  end

  always_comb begin
    fwd_rs2_next = FWD_NONE;
    if (id_next_valid && id_next_rs2 != 5'b0) begin
      if (ex1_w_en && ex1_rd == id_next_rs2) begin
        if (ex1_advances && !ex1_mem_read) fwd_rs2_next = FWD_EX_MEM;
      end else if (ex_mem_w_en && ex_mem_rd == id_next_rs2) begin
        if (ex_mem_advances) fwd_rs2_next = FWD_MEM_WB;
      end else if (mem_wb_stays && mem_wb_w_en && mem_wb_rd == id_next_rs2) begin
        fwd_rs2_next = FWD_MEM_WB;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      fwd_rs1 <= FWD_NONE;
      fwd_rs2 <= FWD_NONE;
    end else begin
      fwd_rs1 <= fwd_rs1_next;
      fwd_rs2 <= fwd_rs2_next;
    end
  end

  // ex_mem_mem_read remains on the interface because the source stage still
  // distinguishes load-vs-ALU producers for hazard/debug symmetry. Once an
  // EX/MEM producer advances to MEM/WB, both load and ALU results are
  // forwardable through the same WB data mux.
  /* verilator lint_off UNUSED */
  logic unused_ex_mem_mem_read;
  assign unused_ex_mem_mem_read = ex_mem_mem_read;
  /* verilator lint_on UNUSED */

endmodule
