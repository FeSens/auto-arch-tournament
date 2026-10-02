// Operand-read consumes registered matches. Late result/trap qualification
// can suppress a younger writer and expose an independently matched older one.
module forward_unit (
  input  logic [4:0] rs1_addr,
  input  logic [4:0] rs2_addr,
  input  provenance_t provenance,
  input  logic [31:0] base_rs1,
  input  logic [31:0] base_rs2,
  /* verilator lint_off UNUSEDSIGNAL */
  input  producer_t ex_fast,
  input  producer_t ex_link,
  input  producer_t ex_completed,
  input  producer_t wb_accepted,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic fast_emit,
  input  logic link_emit,
  input  logic completed_emit,
  input  logic wb_accept,
  input  logic alu_pc_src,
  input  logic alu_imm_src,
  input  logic [31:0] pc,
  input  logic [31:0] imm,
  output logic [31:0] resolved_rs1,
  output logic [31:0] resolved_rs2,
  output logic [31:0] alu_a,
  output logic [31:0] alu_b
);
  logic [2:0] ex_rs1, ex_rs2;
  logic mem_rs1, mem_rs2, any_ex_rs1, any_ex_rs2;
  logic fast_ok, link_ok, completed_ok, mem_ok;
  assign fast_ok = fast_emit && ex_fast.w_en;
  assign link_ok = link_emit && ex_link.w_en;
  assign completed_ok = completed_emit && ex_completed.w_en;
  assign mem_ok = wb_accept && wb_accepted.w_en;
  assign ex_rs1 = {completed_ok, link_ok, fast_ok} & {3{provenance.rs1_ex && rs1_addr != 0}};
  assign ex_rs2 = {completed_ok, link_ok, fast_ok} & {3{provenance.rs2_ex && rs2_addr != 0}};
  assign any_ex_rs1 = |ex_rs1;
  assign any_ex_rs2 = |ex_rs2;
  assign mem_rs1 = provenance.rs1_mem && mem_ok && !any_ex_rs1 && rs1_addr != 0;
  assign mem_rs2 = provenance.rs2_mem && mem_ok && !any_ex_rs2 && rs2_addr != 0;
  assign resolved_rs1 = (ex_fast.data & {32{ex_rs1[0]}})
                      | (ex_link.data & {32{ex_rs1[1]}})
                      | (ex_completed.data & {32{ex_rs1[2]}})
                      | (wb_accepted.data & {32{mem_rs1}})
                      | (base_rs1 & {32{!any_ex_rs1 && !mem_rs1 && rs1_addr != 0}});
  assign resolved_rs2 = (ex_fast.data & {32{ex_rs2[0]}})
                      | (ex_link.data & {32{ex_rs2[1]}})
                      | (ex_completed.data & {32{ex_rs2[2]}})
                      | (wb_accepted.data & {32{mem_rs2}})
                      | (base_rs2 & {32{!any_ex_rs2 && !mem_rs2 && rs2_addr != 0}});

  // Select complete ALU operands alongside each data source, so a late
  // arithmetic word does not traverse a second PC/immediate selection.
  assign alu_a = (pc & {32{alu_pc_src}})
               | (ex_fast.data & {32{ex_rs1[0] && !alu_pc_src}})
               | (ex_link.data & {32{ex_rs1[1] && !alu_pc_src}})
               | (ex_completed.data & {32{ex_rs1[2] && !alu_pc_src}})
               | (wb_accepted.data & {32{mem_rs1 && !alu_pc_src}})
               | (base_rs1 & {32{!any_ex_rs1 && !mem_rs1 && rs1_addr != 0 && !alu_pc_src}});
  assign alu_b = (imm & {32{alu_imm_src}})
               | (ex_fast.data & {32{ex_rs2[0] && !alu_imm_src}})
               | (ex_link.data & {32{ex_rs2[1] && !alu_imm_src}})
               | (ex_completed.data & {32{ex_rs2[2] && !alu_imm_src}})
               | (wb_accepted.data & {32{mem_rs2 && !alu_imm_src}})
               | (base_rs2 & {32{!any_ex_rs2 && !mem_rs2 && rs2_addr != 0 && !alu_imm_src}});
endmodule
