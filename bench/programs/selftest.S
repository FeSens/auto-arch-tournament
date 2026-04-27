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
