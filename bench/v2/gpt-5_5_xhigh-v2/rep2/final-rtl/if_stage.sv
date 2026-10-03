// rtl/if_stage.sv
//
// Instruction fetch stage. Holds the fetch PC plus a two-entry instruction
// FIFO. The memory side keeps presenting the next sequential PC whenever
// the queue has space (or decode is popping this cycle), while the decode
// side consumes only on decode_pop.
//
// When the FIFO is empty and imem is ready, the fetched instruction bypasses
// directly to decode. This preserves the old zero-wait throughput while still
// letting backend stalls fill the queue for later imem stall cover.
//
// Latency:        PC-reg update is synchronous; output is combinational.
// RVFI fields:    feeds pc_rdata (via ID/EX/MEM/WB) and pc_wdata (via
//                 EX-stage redirect).
module if_stage (
  input  logic              clock,
  input  logic              reset,
  input  logic              imem_ready,
  input  logic              decode_pop,
  input  logic              redirect,         // EX has resolved a branch/jump
  input  logic [31:0]       redirect_target,
  input  logic              decode_jal_redirect,
  input  logic [31:0]       decode_jal_redirect_target,
  output logic [31:0]       imem_addr,
  input  logic [31:0]       imem_data,
  output if_id_t  out
);

  localparam logic [31:0] RESET_PC = 32'h0000_0000;

  logic [31:0] fetch_pc_q;
  logic [31:0] pc0_q;
  logic [31:0] pc1_q;
  logic [31:0] instr0_q;
  logic [31:0] instr1_q;
  logic [1:0]  count_q;

  logic        fifo_valid;
  logic        bypass_valid;
  logic        out_valid;
  logic        do_pop;
  logic        do_push;

  assign fifo_valid   = (count_q != 2'd0);
  assign bypass_valid = (count_q == 2'd0) && imem_ready && !redirect;
  assign out_valid    = !redirect && (fifo_valid || bypass_valid);
  assign do_pop       = decode_pop && out_valid;
  assign do_push      = imem_ready && !redirect && ((count_q != 2'd2) || do_pop);

  assign imem_addr = fetch_pc_q;

  always_comb begin
    out.pc    = fifo_valid ? pc0_q    : fetch_pc_q;
    out.instr = fifo_valid ? instr0_q : imem_data;
    out.valid = out_valid;
  end

  // Redirect overrides all queue activity: queued sequential instructions
  // are wrong-path and the next memory request restarts at the target. The
  // decode-JAL redirect intentionally does not suppress out.valid this cycle;
  // it is emitted only after decode accepts the JAL that must keep advancing.
  always_ff @(posedge clock) begin
    if (reset) begin
      fetch_pc_q <= RESET_PC;
      pc0_q      <= 32'b0;
      pc1_q      <= 32'b0;
      instr0_q   <= 32'b0;
      instr1_q   <= 32'b0;
      count_q    <= 2'd0;
    end else if (redirect) begin
      fetch_pc_q <= redirect_target;
      pc0_q      <= 32'b0;
      pc1_q      <= 32'b0;
      instr0_q   <= 32'b0;
      instr1_q   <= 32'b0;
      count_q    <= 2'd0;
    end else if (decode_jal_redirect) begin
      fetch_pc_q <= decode_jal_redirect_target;
      pc0_q      <= 32'b0;
      pc1_q      <= 32'b0;
      instr0_q   <= 32'b0;
      instr1_q   <= 32'b0;
      count_q    <= 2'd0;
    end else begin
      if (do_push) begin
        fetch_pc_q <= fetch_pc_q + 32'd4;
      end

      case (count_q)
        2'd0: begin
          if (do_push && !do_pop) begin
            pc0_q    <= fetch_pc_q;
            instr0_q <= imem_data;
            count_q  <= 2'd1;
          end
        end

        2'd1: begin
          if (do_pop && do_push) begin
            pc0_q    <= fetch_pc_q;
            instr0_q <= imem_data;
            count_q  <= 2'd1;
          end else if (do_pop) begin
            pc0_q    <= 32'b0;
            instr0_q <= 32'b0;
            count_q  <= 2'd0;
          end else if (do_push) begin
            pc1_q    <= fetch_pc_q;
            instr1_q <= imem_data;
            count_q  <= 2'd2;
          end
        end

        default: begin
          if (do_pop && do_push) begin
            pc0_q    <= pc1_q;
            instr0_q <= instr1_q;
            pc1_q    <= fetch_pc_q;
            instr1_q <= imem_data;
            count_q  <= 2'd2;
          end else if (do_pop) begin
            pc0_q    <= pc1_q;
            instr0_q <= instr1_q;
            pc1_q    <= 32'b0;
            instr1_q <= 32'b0;
            count_q  <= 2'd1;
          end
        end
      endcase
    end
  end

endmodule
