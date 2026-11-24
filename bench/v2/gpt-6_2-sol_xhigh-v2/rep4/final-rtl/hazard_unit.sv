// rtl/hazard_unit.sv
//
// Classifies a potential load follower before the fetch head is selected.
module hazard_unit (
  input  logic [4:0] producer_rd,
  input  logic       producer_word,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] instr,
  /* verilator lint_on UNUSEDSIGNAL */
  output load_follower_t follower
);

  logic equality_branch, short_load;

  assign equality_branch = instr[6:0] == 7'b1100011 && instr[14:13] == 2'b00;
  assign short_load = producer_word && instr[6:0] == 7'b0000011
                   && legal_load_funct(instr[14:12]) && instr[31:22] == 10'b0;
  assign follower.rs1 = (producer_rd[4:2] == instr[19:17]) && (producer_rd[1:0] == instr[16:15]);
  assign follower.rs2 = (producer_rd[4:2] == instr[24:22]) && (producer_rd[1:0] == instr[21:20]);
  assign follower.compare = (follower.rs1 || follower.rs2) && equality_branch;
  assign follower.address = follower.rs1 && short_load;
  assign follower.interlock = !equality_branch &&
                              ((follower.rs1 && !short_load) || (follower.rs2 && !follower.rs1));

endmodule
