// rtl/hazard_unit.sv
//
// M-extension results are first available in MEM/WB. A dependent fetch
// retries after a bubble lets the producer advance through MEM.
//
// Latency:        combinational.
// RVFI fields:    n/a (governs validity of subsequent retirements).
module hazard_unit (
  input  logic       id_ex_late_result,
  input  logic [4:0] id_ex_rd,
  input  logic [4:0] if_id_rs1,         // IF/ID instr[19:15]  (next rs1)
  input  logic [4:0] if_id_rs2,         // IF/ID instr[24:20]  (next rs2)
  input  logic       div_wait,          // retain the divide instruction in ID/EX
  input  logic       fetch_valid,
  input  logic       dmem_ready,
  input  logic       ex_request,
  input  logic       repair,
  output logic       stall_id,          // ID/EX register holds (vs. bubble)
  output logic       flush_id,          // ID/EX captures a bubble
  output logic       stall_ex_mem,      // EX/MEM register holds
  output logic       hold_mem_wb        // MEM/WB clears valid only;
                                        // data fields stay (for fwd)
);

  logic late_use_hazard;
  logic dmem_stall;

  always_comb begin
    late_use_hazard = fetch_valid && id_ex_late_result
                   && (id_ex_rd == if_id_rs1 || id_ex_rd == if_id_rs2)
                   && (id_ex_rd != 5'b0);
    dmem_stall = repair || (!dmem_ready && ex_request);

    // Keep the resident EX instruction until it can transfer. Only then
    // may ID/EX be cleared, including its register-write and bus controls.
    stall_id      = dmem_stall || div_wait;
    flush_id      = !stall_id && (late_use_hazard || !fetch_valid);
    // Preserve both forwarding sources for a resident load or store.
    stall_ex_mem  = dmem_stall;
    // A held store can still need its base or data from MEM/WB after that
    // producer retires. MEM/WB clears valid but retains the data and tags.
    hold_mem_wb   = dmem_stall;
  end

endmodule
