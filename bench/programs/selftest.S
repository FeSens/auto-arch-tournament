# Minimal selftest: exercises ALU, load/store (including sub-word), branches.
# Terminates with ebreak on success, loops on failure.
.section .text.start
.global _start
_start:
    # Set up stack
    la   sp, _stack_top

    # ---- ALU ----
    li   t0, 10
    li   t1, 3
    add  t2, t0, t1       # t2 = 13
    li   t3, 13
    bne  t2, t3, fail

    sub  t2, t0, t1       # t2 = 7
    li   t3, 7
    bne  t2, t3, fail

    mul  t2, t0, t1       # t2 = 30
    li   t3, 30
    bne  t2, t3, fail

    # ---- SW / LW ----
    la   a0, scratch
    li   t0, 0xDEADBEEF
    sw   t0, 0(a0)
    lw   t1, 0(a0)
    bne  t0, t1, fail

    # ---- SH / LH at halfword offset 0 ----
    li   t0, 0x1234
    sh   t0, 0(a0)
    lhu  t1, 0(a0)
    bne  t0, t1, fail

    # ---- SH / LH at halfword offset 2 (offset 2 within word) ----
    li   t0, 0xABCD
    sh   t0, 2(a0)
    lhu  t1, 2(a0)
    bne  t0, t1, fail

    # Check the full word now: lower half=0x1234, upper half=0xABCD
    lw   t2, 0(a0)
    li   t3, 0xABCD1234
    bne  t2, t3, fail

    # ---- SB / LB at byte offsets 0-3 ----
    li   t0, 0xAA
    sb   t0, 0(a0)
    lbu  t1, 0(a0)
    bne  t0, t1, fail

    li   t0, 0xBB
    sb   t0, 1(a0)
    lbu  t1, 1(a0)
    bne  t0, t1, fail

    li   t0, 0xCC
    sb   t0, 2(a0)
    lbu  t1, 2(a0)
    bne  t0, t1, fail

    li   t0, 0xDD
    sb   t0, 3(a0)
    lbu  t1, 3(a0)
    bne  t0, t1, fail

    # Verify word = 0xDDCCBBAA
    lw   t2, 0(a0)
    li   t3, 0xDDCCBBAA
    bne  t2, t3, fail

    # ---- Bitwise + shifts ----
    li   t0, 0xF0F0F0F0
    li   t1, 0x0F0F0F0F
    and  t2, t0, t1
    bne  t2, zero, fail            # AND of disjoint bit fields = 0
    or   t2, t0, t1
    li   t3, -1                    # 0xFFFFFFFF
    bne  t2, t3, fail              # OR covers everything
    xor  t2, t0, t1
    bne  t2, t3, fail              # XOR == OR for disjoint
    li   t0, 1
    sll  t2, t0, 5                 # 1 << 5 = 32
    li   t3, 32
    bne  t2, t3, fail
    li   t0, 0x80000000
    srl  t2, t0, 1                 # logical >> 1 = 0x40000000
    li   t3, 0x40000000
    bne  t2, t3, fail
    sra  t2, t0, 1                 # arith  >> 1 = 0xC0000000
    li   t3, 0xC0000000
    bne  t2, t3, fail

    # ---- SLT / SLTU ----
    li   t0, -1
    li   t1, 0
    slt  t2, t0, t1                # signed: -1 < 0 -> 1
    li   t3, 1
    bne  t2, t3, fail
    sltu t2, t0, t1                # unsigned: 0xFFFFFFFF !< 0 -> 0
    bne  t2, zero, fail

    # ---- DIV / REM (M-extension) ----
    li   t0, 10
    li   t1, 3
    div  t2, t0, t1                # 10 / 3 = 3
    li   t3, 3
    bne  t2, t3, fail
    rem  t2, t0, t1                # 10 % 3 = 1
    li   t3, 1
    bne  t2, t3, fail
    li   t0, -7                    # signed: -7 / 2 = -3 (trunc toward zero)
    li   t1, 2
    div  t2, t0, t1
    li   t3, -3
    bne  t2, t3, fail
    li   t1, 0                     # div-by-zero -> -1 (all-ones)
    div  t2, t0, t1
    li   t3, -1
    bne  t2, t3, fail

    # ---- LUI / AUIPC ----
    lui  t0, 0x12345               # t0 = 0x12345000
    li   t3, 0x12345000
    bne  t0, t3, fail
    auipc t0, 0                    # t0 = pc; nonzero (text past start)
    beq  t0, zero, fail

    # ---- BEQ taken/not-taken ----
    li   t0, 7
    li   t1, 7
    beq  t0, t1, beq_taken         # MUST take
    j    fail
beq_taken:
    li   t1, 8
    beq  t0, t1, fail              # MUST NOT take

    # ---- FENCE — architectural NOP, must not trap ----
    fence iorw, iorw

    # ---- JAL / JALR ----
    jal  ra, jal_target
    j    after_jal
jal_target:
    jalr zero, ra, 0
after_jal:

    # ---- Success ----
    ebreak

fail:
    j    fail

.section .bss
scratch: .word 0
