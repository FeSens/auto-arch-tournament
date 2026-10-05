// Resolve OC source enables against EX, MEM, WB, then the ID snapshot.
// Saved sources suppress every live candidate. A matching unavailable nearest
// producer blocks capture and never exposes an older one.
module forward_unit (
  input logic [4:0] rs1_addr, rs2_addr,
  input logic rs1_saved, rs2_saved,
  input logic [4:0] ex_rd, mem_rd, wb_rd,
  input logic ex_writer, mem_writer, wb_writer,
  input logic ex_ready, mem_ready,
  output logic rs1_ready, rs2_ready,
  // [4:0] = saved, EX, MEM, WB, ID. All enables are zero for x0.
  output logic [4:0] rs1_select, rs2_select
);
  logic near1, near2, middle1, middle2, far1, far2, captured1, captured2;
  assign near1 = rs1_addr != 0 && ex_writer && ex_rd != 0 && ex_rd == rs1_addr;
  assign near2 = rs2_addr != 0 && ex_writer && ex_rd != 0 && ex_rd == rs2_addr;
  assign middle1 = rs1_addr != 0 && mem_writer && mem_rd != 0 && mem_rd == rs1_addr && !near1;
  assign middle2 = rs2_addr != 0 && mem_writer && mem_rd != 0 && mem_rd == rs2_addr && !near2;
  assign far1 = rs1_addr != 0 && wb_writer && wb_rd != 0 && wb_rd == rs1_addr && !near1 && !middle1;
  assign far2 = rs2_addr != 0 && wb_writer && wb_rd != 0 && wb_rd == rs2_addr && !near2 && !middle2;
  assign captured1 = rs1_addr != 0 && !(near1 || middle1 || far1);
  assign captured2 = rs2_addr != 0 && !(near2 || middle2 || far2);
  assign rs1_ready = rs1_saved || ((!near1 || ex_ready) && (!middle1 || mem_ready));
  assign rs2_ready = rs2_saved || ((!near2 || ex_ready) && (!middle2 || mem_ready));
  // Availability controls the capture edge, never the wide data enables.
  assign rs1_select = {rs1_saved && rs1_addr != 0,
                      {4{!rs1_saved}} & {near1, middle1, far1, captured1}};
  assign rs2_select = {rs2_saved && rs2_addr != 0,
                      {4{!rs2_saved}} & {near2, middle2, far2, captured2}};
endmodule
