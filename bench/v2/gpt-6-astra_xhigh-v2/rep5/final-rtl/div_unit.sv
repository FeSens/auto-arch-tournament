// Shared blocking RV32M divider. Service edges: capture/magnitudes/two
// narrow steps, six radix-8/radix-4 groups, corrected acceptance.
// DONE persists under backpressure; reset cancels any pending operation.
module div_unit (
  input  logic        clock,
  input  logic        reset,
  input  logic        start,
  input  logic [4:0]  op,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        busy,
  output logic        result_valid,
  output logic [31:0] result,
  input  logic        result_accept
);
  typedef enum logic [2:0] {
    IDLE, STEP0, STEP1, STEP2, STEP3, STEP4, STEP5, DONE
  } state_t;
  state_t state;
  logic [31:0] a_q, b_q;
  // The real datapath uses decoded sign/selection flags; ALTOPS uses op_q.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0] op_q;
  /* verilator lint_on UNUSEDSIGNAL */

`ifndef RISCV_FORMAL_ALTOPS
  logic [31:0] quotient, remainder, divisor;
  logic negate_q, negate_r, select_rem;
  logic signed_op;
  logic [31:0] magnitude_a, magnitude_b;
  logic [1:0] first_difference;
  logic [2:0] second_difference;
  logic first_bit, second_bit, first_remainder;
  logic [1:0] initial_remainder;
  logic [34:0] divisor3, divisor5, divisor7, magnitude_b_wide;
  logic [34:0] multiples [1:7];
  logic [34:0] trial8;
  logic [33:0] trial4;
  logic [35:0] difference8 [1:7];
  logic [34:0] difference4 [1:3];
  logic [7:1] fit8;
  logic [3:1] fit4;
  logic [7:0] enable8;
  logic [3:0] enable4;
  logic [31:0] masked8 [0:7];
  logic [31:0] masked4 [0:3];
  logic [2:0] digit8;
  logic [1:0] digit4;
  logic [31:0] q_after8, r_after8, q_next, r_next;
  logic [31:0] result_magnitude;
  logic result_negative;

  // Consume the top two magnitude bits on the launch edge. The trial
  // remainders have only one and two significant bits, respectively.
  // Reject large divisors before using each narrow unsigned borrow bit.
  // Negating INT_MIN deliberately leaves the unsigned magnitude 0x80000000.
  always_comb begin
    signed_op = op == ALU_DIV || op == ALU_REM;
    magnitude_a = (signed_op && a[31]) ? -a : a;
    magnitude_b = (signed_op && b[31]) ? -b : b;
    first_difference = {1'b0, magnitude_a[31]} - {1'b0, magnitude_b[0]};
    first_bit = !(|magnitude_b[31:1]) && !first_difference[1];
    first_remainder = first_bit ? first_difference[0] : magnitude_a[31];
    second_difference = {1'b0, first_remainder, magnitude_a[30]}
                      - {1'b0, magnitude_b[1:0]};
    second_bit = !(|magnitude_b[31:2]) && !second_difference[2];
    initial_remainder = second_bit ? second_difference[1:0]
                                  : {first_remainder, magnitude_a[30]};
  end

  // Each launch multiple is independently formed from the widened new
  // magnitude. Recurrence uses only frozen registers and wiring shifts.
  assign magnitude_b_wide = {3'b0, magnitude_b};
  assign multiples[1] = {3'b0, divisor};
  assign multiples[2] = {2'b0, divisor, 1'b0};
  assign multiples[3] = divisor3;
  assign multiples[4] = {1'b0, divisor, 2'b0};
  assign multiples[5] = divisor5;
  assign multiples[6] = divisor3 << 1;
  assign multiples[7] = divisor7;

  // Parallel unsigned trials with a genuine extra borrow bit. Monotonic
  // fits decode one-hot digits; balanced masked-OR trees avoid priority
  // mux chains. For D=0 all fits are true and the largest digit wins.
  always_comb begin
    trial8 = {remainder, quotient[31:29]};
    for (int k = 1; k <= 7; k++) begin
      difference8[k] = {1'b0, trial8} - {1'b0, multiples[k]};
      fit8[k] = !difference8[k][35];
    end
    enable8[0] = !fit8[1];
    for (int k = 1; k < 7; k++) enable8[k] = fit8[k] && !fit8[k+1];
    enable8[7] = fit8[7];
    masked8[0] = trial8[31:0] & {32{enable8[0]}};
    for (int k = 1; k <= 7; k++)
      masked8[k] = difference8[k][31:0] & {32{enable8[k]}};
    r_after8 = ((masked8[0] | masked8[1]) | (masked8[2] | masked8[3])) |
               ((masked8[4] | masked8[5]) | (masked8[6] | masked8[7]));
    digit8[0] = (enable8[1] | enable8[3]) | (enable8[5] | enable8[7]);
    digit8[1] = (enable8[2] | enable8[3]) | (enable8[6] | enable8[7]);
    digit8[2] = (enable8[4] | enable8[5]) | (enable8[6] | enable8[7]);
    q_after8 = {quotient[28:0], digit8};

    trial4 = {r_after8, q_after8[31:30]};
    for (int k = 1; k <= 3; k++) begin
      // kD <= 3*(2^32-1), so 34 magnitude bits are sufficient here.
      difference4[k] = {1'b0, trial4} - {1'b0, multiples[k][33:0]};
      fit4[k] = !difference4[k][34];
    end
    enable4[0] = !fit4[1];
    enable4[1] = fit4[1] && !fit4[2];
    enable4[2] = fit4[2] && !fit4[3];
    enable4[3] = fit4[3];
    masked4[0] = trial4[31:0] & {32{enable4[0]}};
    for (int k = 1; k <= 3; k++)
      masked4[k] = difference4[k][31:0] & {32{enable4[k]}};
    r_next = (masked4[0] | masked4[1]) | (masked4[2] | masked4[3]);
    digit4 = {enable4[2] | enable4[3], enable4[1] | enable4[3]};
    q_next = {q_after8[29:0], digit4};
  end
`endif

  assign busy = state != IDLE;
  assign result_valid = state == DONE;

  // Every source is captured at launch or registered by the last STEP.
  // DONE freezes those sources, including during arbitrarily long holds.
  // EX/MEM captures this correction on service edge eight, with no SIGN
  // register or extra completion handoff cycle inside the divider.
  always_comb begin
`ifdef RISCV_FORMAL_ALTOPS
    case (op_q)
      ALU_DIV:  result = (a_q - b_q) ^ 32'h7f8529ec;
      ALU_DIVU: result = (a_q - b_q) ^ 32'h10e8fd70;
      ALU_REM:  result = (a_q - b_q) ^ 32'h8da68fa5;
      ALU_REMU: result = (a_q - b_q) ^ 32'h3138d0e1;
      default:  result = '0;
    endcase
`else
    // INT_MIN / -1 naturally gives 0x80000000 and remainder 0.
    result_magnitude = select_rem ? remainder : quotient;
    result_negative = select_rem ? negate_r : negate_q;
    if (b_q == 0)
      result = select_rem ? a_q : 32'hffffffff;
    else
      result = result_negative ? -result_magnitude : result_magnitude;
`endif
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      state <= IDLE;
      a_q <= '0;
      b_q <= '0;
      op_q <= '0;
`ifndef RISCV_FORMAL_ALTOPS
      quotient <= '0;
      remainder <= '0;
      divisor <= '0;
      divisor3 <= '0;
      divisor5 <= '0;
      divisor7 <= '0;
      negate_q <= 1'b0;
      negate_r <= 1'b0;
      select_rem <= 1'b0;
`endif
    end else begin
      case (state)
        IDLE: if (start) begin
          a_q <= a;
          b_q <= b;
          op_q <= op;
`ifndef RISCV_FORMAL_ALTOPS
          quotient <= {magnitude_a[29:0], first_bit, second_bit};
          remainder <= {30'b0, initial_remainder};
          divisor <= magnitude_b;
          divisor3 <= magnitude_b_wide + (magnitude_b_wide << 1);
          divisor5 <= magnitude_b_wide + (magnitude_b_wide << 2);
          divisor7 <= (magnitude_b_wide << 3) - magnitude_b_wide;
          negate_q <= (op == ALU_DIV) && (a[31] ^ b[31]);
          negate_r <= (op == ALU_REM) && a[31];
          select_rem <= op == ALU_REM || op == ALU_REMU;
`endif
          state <= STEP0;
        end
        STEP0, STEP1, STEP2, STEP3, STEP4, STEP5: begin
`ifndef RISCV_FORMAL_ALTOPS
          quotient <= q_next;
          remainder <= r_next;
`endif
          case (state)
            STEP0: state <= STEP1;
            STEP1: state <= STEP2;
            STEP2: state <= STEP3;
            STEP3: state <= STEP4;
            STEP4: state <= STEP5;
            default: state <= DONE;
          endcase
        end
        DONE: if (result_accept) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
