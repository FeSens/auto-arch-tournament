// rtl/if_stage.sv
//
// The instruction in EX selects its successor on the combinational imem
// bus. When ID/EX takes a bubble, retry the address presented on that edge.
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              ex_valid,
  input  logic [31:0]       ex_pc,
  input  logic [8:0]        ex_word_disp,
  input  logic              ex_likely_direct,
  input  logic              ex_fence_i,
  input  logic              stall,
  input  logic              imem_ready,
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output logic              annul,
  output if_id_t  out
);

  logic [31:0] retry_pc, fallthrough_pc;

  always_ff @(posedge clock) begin
    if (reset) retry_pc <= 32'b0;
    else       retry_pc <= imem_addr;
  end

  assign fallthrough_pc = ex_pc + 32'd4;
  assign imem_addr = redirect ? redirect_target
                   : ex_valid ? fallthrough_pc : retry_pc;

  // Write a live response one edge later, once retry_pc contains its address.
  // Keep rs1 in distributed RAM so its registered output can drive ID early.
  (* syn_ramstyle = "block_ram", ram_style = "block" *)
  logic [50:0] successors [0:511];
  (* syn_ramstyle = "distributed_ram", ram_style = "distributed" *)
  logic [19:15] insn_fast [0:511];
  logic        clearing, train_q, write_enable;
  logic [8:0]  clear_index, train_index_q, write_index;
  logic [31:0] train_insn_q;

  always_ff @(posedge clock) begin
    if (reset || ex_fence_i) begin
      clearing    <= 1'b1;
      clear_index <= '0;
    end else if (clearing) begin
      clearing    <= !(&clear_index);
      clear_index <= clear_index + 9'd1;
    end

    train_q <= !reset && !ex_fence_i && !clearing && !stall &&
               imem_ready && ex_valid && ex_pc[31:20] == 0 && ex_pc[1:0] == 0;
    train_index_q <= ex_pc[10:2];
    train_insn_q  <= imem_data;
  end

  assign write_enable = clearing || (train_q && !reset && !ex_fence_i &&
                                     retry_pc[31:20] == 0 && retry_pc[1:0] == 0);
  assign write_index = clearing ? clear_index : train_index_q;

  // Look up the likely next predecessor. A wrong read index can only reduce
  // coverage, since the stored destination is verified independently.
  logic [8:0]  read_index;
  logic [50:0] row_q;
  logic [19:15] early_q;
  logic        read_usable_q;
  assign read_index = ex_valid ? ex_pc[10:2] + (ex_likely_direct ? ex_word_disp : 9'd1)
                               : retry_pc[10:2];
  always_ff @(posedge clock) begin
    if (write_enable) begin
      successors[write_index] <= {!clearing, retry_pc[19:2], train_insn_q};
      insn_fast[write_index] <= train_insn_q[19:15];
    end
    if (!stall) begin
      row_q <= successors[read_index];
      early_q <= insn_fast[read_index];
    end
  end

  always_ff @(posedge clock) begin
    if (reset || ex_fence_i || clearing)
      read_usable_q <= 1'b0;
    else if (!stall)
      read_usable_q <= !(write_enable && read_index == write_index);
  end

  // Decode a denied fetch provisionally. Register the two full-width address
  // comparisons in parallel with EX's redirect decision beside the candidate.
  logic [31:0] saved_pc;
  logic        match_linear_q, match_target_q, redirect_q, denied_q;
  assign saved_pc = {12'b0, row_q[49:32], 2'b00};
  always_ff @(posedge clock) begin
    if (!stall) begin
      match_linear_q <= saved_pc == fallthrough_pc;
      match_target_q <= saved_pc == redirect_target;
      redirect_q     <= redirect;
    end
    if (reset)       denied_q <= 1'b0;
    else if (!stall) denied_q <= !imem_ready;
  end
  assign annul = denied_q && !(redirect_q ? match_target_q : match_linear_q);

  always_comb begin
    out.pc    = imem_addr;
    out.instr = imem_ready ? imem_data : row_q[31:0];
    out.instr[19:15] = imem_ready ? imem_data[19:15] : early_q;
    out.valid = !ex_fence_i && (imem_ready || (ex_valid && read_usable_q && row_q[50]));
  end

endmodule
