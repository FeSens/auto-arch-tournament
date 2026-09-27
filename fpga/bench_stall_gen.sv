// fpga/bench_stall_gen.sv
//
// Memory-ready generator for the timed FPGA wrapper (HWE Bench V2).
//
// It reproduces, cycle for cycle, the bus backpressure that
// test/cosim/main.cpp applies when CoreMark is run for fitness
// (--istall --dstall): an xorshift32 seeded with 0xDEADBEEF, advanced
// twice per cycle (first draw -> imem ready, second draw -> dmem ready),
// accepting when (state & 0x7F) < 100.
//
// Why it exists: in V1 the wrapper tied both ready signals to 1, so
// synthesis deleted any core logic that only acts while a ready is low.
// That logic then saved simulated cycles at no area or timing cost. With
// the ready signals driven by this generator, the timed netlist is the
// circuit whose cycles are counted.
//
// Both ready outputs come straight from flip-flops, so the generator adds
// no combinational depth to paths inside the core. The reset values hold
// the first cycle's draws; each clock precomputes the next cycle's pair.
module bench_stall_gen (
  input  logic clock,
  input  logic reset,
  output logic imem_ready,
  output logic dmem_ready
);

  function automatic [31:0] xs32(input [31:0] s);
    reg [31:0] t;
    begin
      t = s ^ (s << 13);
      t = t ^ (t >> 17);
      xs32 = t ^ (t << 5);
    end
  endfunction

  function automatic accept(input [31:0] s);
    accept = (s[6:0] < 7'd100);
  endfunction

  // State after the two draws of the current cycle.
  logic [31:0] state;
  logic [31:0] next_i, next_d;
  assign next_i = xs32(state);
  assign next_d = xs32(next_i);

  // Reset values: state after the two draws of cycle 0, and the accept
  // bits of those two draws (seed 0xDEADBEEF; see test_bench_stall_gen.py).
  always_ff @(posedge clock or posedge reset) begin
    if (reset) begin
      state      <= 32'h8E1D9142;
      imem_ready <= 1'b1;
      dmem_ready <= 1'b1;
    end else begin
      state      <= next_d;
      imem_ready <= accept(next_i);
      dmem_ready <= accept(next_d);
    end
  end

endmodule
