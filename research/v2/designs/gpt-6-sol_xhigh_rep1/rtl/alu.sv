// rtl/alu.sv
//
// RV32IM combinational ALU. Select bits are decoded and registered in ID.
// DIV/REM are executed by div_unit in EX.
//
// Latency:        combinational (0 cycles).
// RVFI fields:    feeds rd_wdata (via EX/MEM/WB), branch resolution, mem_addr.
module alu (
  input  logic [ALU_SEL_COUNT-1:0] sel,
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic [31:0] out
);

  logic        [4:0]  shamt;
  logic [31:0] add_result, sub_result;
  logic [31:0] mul_result, mulh_result, mulhu_result, mulhsu_result;
  logic [31:0] div_result, divu_result, rem_result, remu_result;

  // 64-bit products, computed once and selected per op.
  // mul_ss/mul_su low halves are unused (only MULH/MULHSU read the high
  // half). Verilator's UNUSEDSIGNAL is silenced locally — the unused
  // bits are dead-code-eliminated by Yosys.
`ifndef RISCV_FORMAL_ALTOPS
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [63:0] mul_ss;  // signed*signed
  logic        [63:0] mul_uu;  // unsigned*unsigned (both halves used)
  logic signed [63:0] mul_su;  // signed*unsigned (a signed, b unsigned)
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  always_comb begin
    shamt = b[4:0];

    add_result = a + b;
    sub_result = a - b;

    // MUL stays single-cycle. Under RISCV_FORMAL_ALTOPS the ALU's
    // M-extension outputs use the riscv-formal algebraic stand-ins;
    // div_unit applies the matching DIV/REM stand-ins at completion.
`ifdef RISCV_FORMAL_ALTOPS
    mul_result    = add_result ^ 32'h5876063e;
    mulh_result   = add_result ^ 32'hf6583fb7;
    mulhu_result  = add_result ^ 32'h949ce5e8;
    mulhsu_result = sub_result ^ 32'hecfbe137;
    div_result    = sub_result ^ 32'h7f8529ec;
    divu_result   = sub_result ^ 32'h10e8fd70;
    rem_result    = sub_result ^ 32'h8da68fa5;
    remu_result   = sub_result ^ 32'h3138d0e1;
`else
    mul_ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    mul_uu = {32'b0, a} * {32'b0, b};
    mul_su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
    mul_result    = mul_uu[31:0];
    mulh_result   = $unsigned(mul_ss[63:32]);
    mulhu_result  = mul_uu[63:32];
    mulhsu_result = $unsigned(mul_su[63:32]);
    div_result    = '0;
    divu_result   = '0;
    rem_result    = '0;
    remu_result   = '0;
`endif

    // Select the parallel results using the registered one-hot bits.
    out = ({32{sel[ALU_ADD]}}    & add_result)
        | ({32{sel[ALU_SUB]}}    & sub_result)
        | ({32{sel[ALU_AND]}}    & (a & b))
        | ({32{sel[ALU_OR]}}     & (a | b))
        | ({32{sel[ALU_XOR]}}    & (a ^ b))
        | ({32{sel[ALU_SLT]}}    & {31'b0, ($signed(a) < $signed(b))})
        | ({32{sel[ALU_SLTU]}}   & {31'b0, (a < b)})
        | ({32{sel[ALU_SLL]}}    & (a << shamt))
        | ({32{sel[ALU_SRL]}}    & (a >> shamt))
        | ({32{sel[ALU_SRA]}}    & $unsigned($signed(a) >>> shamt))
        | ({32{sel[ALU_LUI]}}    & b)
        | ({32{sel[ALU_MUL]}}    & mul_result)
        | ({32{sel[ALU_MULH]}}   & mulh_result)
        | ({32{sel[ALU_MULHU]}}  & mulhu_result)
        | ({32{sel[ALU_MULHSU]}} & mulhsu_result)
        | ({32{sel[ALU_DIV]}}    & div_result)
        | ({32{sel[ALU_DIVU]}}   & divu_result)
        | ({32{sel[ALU_REM]}}    & rem_result)
        | ({32{sel[ALU_REMU]}}   & remu_result);
  end

endmodule
