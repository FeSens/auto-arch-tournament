// rtl/hazard_unit.sv
//
// Hold an adjacent consumer for one cycle if its producer's result is
// first available for collection in MEM.
//
// Both younger stages hold on backpressure. A dependency holds only
// decode/fetch and inserts a bubble between the producer and consumer.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_result, // high multiply or divide in EX
  input  logic [4:0] id_ex_rd,          // ID/EX.rd
  input  logic [4:0] waiting_rs1,
  input  logic [4:0] waiting_rs2,
  input  logic       div_wait,          // divider owns ID/EX until result transfer
  input  logic       fetch_available,   // external response or verified replay
  input  logic       mem_wait,
  input  logic       repair,
  output logic       stall_if,          // PC reg holds
  output logic       stall_id,          // decoded consumer stays in collection
  output logic       stall_ex,          // EX input holds
  output logic       result_hazard
);

  always_comb begin
    result_hazard = id_ex_late_result
                 && (id_ex_rd == waiting_rs1 || id_ex_rd == waiting_rs2)
                 && (id_ex_rd != 5'b0);
    stall_ex = mem_wait || div_wait || repair;
    stall_id = stall_ex || result_hazard;
    stall_if = stall_id || !fetch_available;
  end

endmodule
