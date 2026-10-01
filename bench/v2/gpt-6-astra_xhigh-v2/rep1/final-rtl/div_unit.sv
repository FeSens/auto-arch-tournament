// Blocking RV32M divider with dedicated prefix banks: consume 2 bits at
// launch, then 6,4,4,4,4,4,4 bits across seven register boundaries. Sign
// correction and transfer retain the nine-cycle EX occupancy. A blocked
// completion is registered until accept.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        accept,
  output logic        busy,
  output logic        done,
  output logic [31:0] result
);
  logic active_q, complete_q;
  logic [2:0] iteration_q;
  logic [31:0] result_q, final_result;

`ifdef RISCV_FORMAL_ALTOPS
  logic [31:0] alt_result_q;
  always_ff @(posedge clock) begin
    if (reset) alt_result_q <= 32'b0;
    else if (start && !busy) begin
      case (op)
        ALU_DIV:  alt_result_q <= (a - b) ^ 32'h7f8529ec;
        ALU_DIVU: alt_result_q <= (a - b) ^ 32'h10e8fd70;
        ALU_REM:  alt_result_q <= (a - b) ^ 32'h8da68fa5;
        ALU_REMU: alt_result_q <= (a - b) ^ 32'h3138d0e1;
        default:  alt_result_q <= 32'b0;
      endcase
    end
  end
  assign final_result = alt_result_q;
`else
  logic [31:0] divisor_q;
  logic [33:0] triple_divisor_q;
  logic [31:0] quotient_bank [0:7];
  logic [31:0] remainder_bank [0:7];
  // Observation only: execution always reads a statically selected bank.
  /* verilator lint_off UNUSEDSIGNAL */
  wire [31:0] quotient_q = quotient_bank[iteration_q];
  wire [31:0] remainder_q = remainder_bank[iteration_q];
  /* verilator lint_on UNUSEDSIGNAL */
  logic quotient_negative_q, remainder_negative_q, select_remainder_q;
  logic zero_divisor_q;
  logic signed_op;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic large_divisor;
  wire [1:0] launch_quotient;
  wire [1:0] launch_remainder [0:2];
  logic [31:0] magnitude;
  logic negative_result;

  assign signed_op = (op == ALU_DIV || op == ALU_REM);
  assign dividend_magnitude = signed_op && a[31] ? -a : a;
  assign divisor_magnitude = signed_op && b[31] ? -b : b;
  assign large_divisor = |divisor_magnitude[31:2];

  // The launch prefix is at most three. D >= 4 therefore yields q2=0,
  // r2=A[31:30]; otherwise two two-bit restoring steps suffice. The
  // extra subtraction bit records borrow. D=0 naturally yields q2=3.
  assign launch_remainder[0] = 2'b0;
  for (genvar launch_bit = 0; launch_bit < 2; launch_bit++) begin : first_pair
    wire [1:0] trial = {launch_remainder[launch_bit][0],
                        dividend_magnitude[31-launch_bit]};
    wire [2:0] difference = {1'b0, trial} - {1'b0, divisor_magnitude[1:0]};
    assign launch_remainder[launch_bit+1] = difference[2] ? trial : difference[1:0];
    assign launch_quotient[1-launch_bit] = !difference[2];
  end

  // Compute full 3D once, alongside the first recurrence, never on launch
  // or in a dependent digit chain. Its 34 bits preserve all overflow bits.
  always_ff @(posedge clock) begin
    if (reset) triple_divisor_q <= 34'b0;
    else if (active_q && !complete_q && iteration_q == 3'd0)
      triple_divisor_q <= {2'b0, divisor_q} + {1'b0, divisor_q, 1'b0};
  end

  for (genvar p = 0; p < 7; p++) begin : phase
    localparam integer C = p == 0 ? 2 : 4 + 4*p;
    localparam integer N = p == 0 ? 6 : 4;
    localparam integer P = C + N;
    localparam integer W = P + 2;
    localparam integer DIGITS = N / 2;
    wire large_d;
    wire [W-1:0] d1, d2, d3;
    wire [31:0] qstep [0:DIGITS];
    wire [W-1:0] rstep [0:DIGITS];

    if (P < 32) begin : bounded
      assign large_d = |divisor_q[31:P];
    end else begin : full_width
      assign large_d = 1'b0;
    end
    assign d1 = {2'b0, divisor_q[P-1:0]};
    assign d2 = d1 << 1;
    if (p == 0) begin : local_triple
      assign d3 = d1 + d2;
    end else begin : registered_triple
      assign d3 = triple_divisor_q[W-1:0];
    end
    assign qstep[0] = quotient_bank[p];
    assign rstep[0] = {{(W-C){1'b0}}, remainder_bank[p][C-1:0]};

    for (genvar digit = 0; digit < DIGITS; digit++) begin : radix4
      wire [W-1:0] trial = {rstep[digit][W-3:0], qstep[digit][31:30]};
      wire [W:0] diff1 = {1'b0, trial} - {1'b0, d1};
      wire [W:0] diff2 = {1'b0, trial} - {1'b0, d2};
      wire [W:0] diff3 = {1'b0, trial} - {1'b0, d3};
      wire take3 = !diff3[W];
      wire take2 = diff3[W] && !diff2[W];
      // Ordered exact multiples make adjacent borrow boundaries exclusive.
      // Any truncated-multiple case is discarded by the large-D bypass.
      wire take1 = diff2[W] && !diff1[W];
      wire take0 = diff1[W];
      assign rstep[digit+1] = (diff3[W-1:0] & {W{take3}})
                           | (diff2[W-1:0] & {W{take2}})
                           | (diff1[W-1:0] & {W{take1}})
                           | (trial & {W{take0}});
      // The digit's high bit is set exactly when trial >= 2D.
      assign qstep[digit+1] = {qstep[digit][29:0], !diff2[W], take3 | take1};
    end

    // No selected-bank feedback mux: each phase reads only its predecessor
    // and has its own enabled successor register. Large divisors cannot
    // subtract from this prefix, so bypass all truncated divisor multiples.
    always_ff @(posedge clock) begin
      if (reset) begin
        quotient_bank[p+1] <= 32'b0;
        remainder_bank[p+1] <= 32'b0;
      end else if (active_q && !complete_q && iteration_q == 3'(p)) begin
        quotient_bank[p+1] <= large_d ? quotient_bank[p] << N : qstep[DIGITS];
        remainder_bank[p+1] <= large_d
                              ? (remainder_bank[p] << N) | (quotient_bank[p] >> (32-N))
                              : 32'(rstep[DIGITS]);
      end
    end
  end

  always_comb begin
    magnitude = select_remainder_q ? remainder_bank[7] : quotient_bank[7];
    negative_result = select_remainder_q ? remainder_negative_q : quotient_negative_q;
    final_result = negative_result ? -magnitude : magnitude;
    // With divisor zero, restoring leaves the dividend as remainder.
    // Only the quotient needs an override, to suppress sign correction.
    // INT_MIN/-1 naturally produces 0x80000000 and remainder zero.
    if (zero_divisor_q && !select_remainder_q) final_result = 32'hffffffff;
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      divisor_q <= 32'b0;
      quotient_bank[0] <= 32'b0;
      remainder_bank[0] <= 32'b0;
      quotient_negative_q <= 1'b0;
      remainder_negative_q <= 1'b0;
      select_remainder_q <= 1'b0;
      zero_divisor_q <= 1'b0;
    end else if (start && !busy) begin
      divisor_q <= divisor_magnitude;
      quotient_bank[0] <= {dividend_magnitude[29:0],
                           large_divisor ? 2'b0 : launch_quotient};
      remainder_bank[0] <= {30'b0, large_divisor ? dividend_magnitude[31:30]
                                                : launch_remainder[2]};
      quotient_negative_q <= signed_op && (a[31] ^ b[31]);
      remainder_negative_q <= signed_op && a[31];
      select_remainder_q <= (op == ALU_REM || op == ALU_REMU);
      zero_divisor_q <= (b == 32'b0);
    end
  end
`endif

  assign busy = active_q;
  assign done = active_q && (complete_q || iteration_q == 3'd7);
  assign result = complete_q ? result_q : final_result;

  // Identical scheduling for real arithmetic, exceptional operands and
  // ALTOPS: never shorten just the formal model's execution latency.
  always_ff @(posedge clock) begin
    if (reset) begin
      active_q <= 1'b0;
      complete_q <= 1'b0;
      iteration_q <= 3'b0;
      result_q <= 32'b0;
    end else if (start && !busy) begin
      active_q <= 1'b1;
      complete_q <= 1'b0;
      iteration_q <= 3'b0;
    end else if (done && accept) begin
      active_q <= 1'b0;
      complete_q <= 1'b0;
    end else if (active_q && !complete_q) begin
      if (iteration_q == 3'd7) begin
        result_q <= final_result;
        complete_q <= 1'b1;
      end else iteration_q <= iteration_q + 3'd1;
    end
  end
endmodule
