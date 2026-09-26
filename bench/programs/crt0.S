.section .text.start
.global _start
_start:
    la   sp, _stack_top
    li   a0, 0
    li   a1, 0
    call main
    ebreak
1:  j    1b
