#!/usr/bin/env python3
"""RV32IM reference interpreter. Modifications require explicit user approval."""
import struct, sys
from dataclasses import dataclass, field
from typing import Optional

XLEN = 32
MASK = (1 << XLEN) - 1
MEM_BYTES = 1 << 20  # 1 MiB

# MMIO UART mirrors main.cpp's model: writes in this range are consumed by
# the testbench; reads are undefined. The reference returns 0 for UART reads
# and discards UART writes, matching main.cpp's behavior.
UART_BASE = 0x10000000
UART_MASK = 0xFFF00000

@dataclass
class RV32IM:
    mem: bytearray = field(default_factory=lambda: bytearray(MEM_BYTES))
    regs: list = field(default_factory=lambda: [0] * 32)
    pc: int = 0
    retired: int = 0
    oob_access: bool = False
    uart_buf: bytearray = field(default_factory=bytearray)

    def load_elf(self, path: str):
        data = open(path, 'rb').read()
        assert data[:4] == b'\x7fELF'
        e_phoff     = struct.unpack_from('<I', data, 28)[0]
        e_phentsize = struct.unpack_from('<H', data, 42)[0]
        e_phnum     = struct.unpack_from('<H', data, 44)[0]
        self.pc     = struct.unpack_from('<I', data, 24)[0]
        for i in range(e_phnum):
            off      = e_phoff + i * e_phentsize
            p_type   = struct.unpack_from('<I', data, off)[0]
            p_offset = struct.unpack_from('<I', data, off+4)[0]
            p_vaddr  = struct.unpack_from('<I', data, off+8)[0]
            p_filesz = struct.unpack_from('<I', data, off+16)[0]
            if p_type == 1:
                self.mem[p_vaddr:p_vaddr+p_filesz] = data[p_offset:p_offset+p_filesz]

    def _in_uart(self, a): return (a & UART_MASK) == UART_BASE
    def _in_mem (self, a): return a < MEM_BYTES

    def rw(self, addr):
        if self._in_uart(addr): self.oob_access = True; return 0
        if not self._in_mem(addr): self.oob_access = True
        return struct.unpack_from('<I', self.mem, addr & 0xFFFFFC)[0]
    def rb(self, addr):
        if self._in_uart(addr): self.oob_access = True; return 0
        if not self._in_mem(addr): self.oob_access = True
        return self.mem[addr & (MEM_BYTES - 1)]
    def rhw(self, addr):
        if self._in_uart(addr): self.oob_access = True; return 0
        if not self._in_mem(addr): self.oob_access = True
        return struct.unpack_from('<H', self.mem, addr & (MEM_BYTES - 2))[0]
    def ww(self, addr, v):
        if self._in_uart(addr):
            self.uart_buf.extend(((v >> (i*8)) & 0xFF) for i in range(4))
            return
        if not self._in_mem(addr): self.oob_access = True
        struct.pack_into('<I', self.mem, addr & 0xFFFFFC, v & MASK)
    def wb(self, addr, v):
        if self._in_uart(addr):
            self.uart_buf.append(v & 0xFF); return
        if not self._in_mem(addr): self.oob_access = True
        self.mem[addr & (MEM_BYTES - 1)] = v & 0xFF
    def whw(self, addr, v):
        if self._in_uart(addr):
            self.uart_buf.extend(((v >> (i*8)) & 0xFF) for i in range(2)); return
        if not self._in_mem(addr): self.oob_access = True
        struct.pack_into('<H', self.mem, addr & (MEM_BYTES - 2), v & 0xFFFF)
    def sx(self, v, bits): return v - (1 << bits) if v >> (bits-1) else v

    @staticmethod
    def trunc_div(a, b):
        """RISC-V signed division: truncate toward zero (C semantics), not Python floor."""
        q = abs(a) // abs(b)
        return -q if (a < 0) ^ (b < 0) else q

    @staticmethod
    def trunc_rem(a, b):
        """RISC-V signed remainder: sign of result = sign of dividend (trunc-toward-zero)."""
        r = abs(a) % abs(b)
        return -r if a < 0 else r

    def step(self) -> Optional[dict]:
        instr = self.rw(self.pc)
        op  = instr & 0x7F
        rd  = (instr >> 7)  & 0x1F
        fn3 = (instr >> 12) & 0x7
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        fn7 = (instr >> 25) & 0x7F

        imm_i = self.sx((instr >> 20), 12)
        imm_s = self.sx(((instr>>25)<<5)|((instr>>7)&0x1F), 12)
        imm_b = self.sx(((instr>>31)<<12)|(((instr>>7)&1)<<11)|(((instr>>25)&0x3F)<<5)|(((instr>>8)&0xF)<<1), 13)
        imm_u = instr & 0xFFFFF000
        imm_j = self.sx(((instr>>31)<<20)|(((instr>>12)&0xFF)<<12)|(((instr>>20)&1)<<11)|(((instr>>21)&0x3FF)<<1), 21)

        r = self.regs; pc = self.pc; npc = pc + 4
        wrd = wval = 0
        mem_addr = mem_wmask = mem_wdata = mem_rmask = mem_rdata = 0
        # Snapshot rs1/rs2 BEFORE writing rd — RVFI requires reporting the values
        # the instruction consumed, which differ from the post-execution register
        # when rd == rs1 or rd == rs2.
        rs1_rdata_pre = self.regs[rs1]
        rs2_rdata_pre = self.regs[rs2]

        if op == 0x33:  # R-type
            a, b = r[rs1], r[rs2]; sa, sb = self.sx(a,32), self.sx(b,32)
            if fn7 == 0x00:
                v = [a+b, a<<(b&31), int(sa<sb), int(a<b), a^b, a>>(b&31), a|b, a&b][fn3]
                if fn3 == 5: v = a >> (b&31)
            elif fn7 == 0x20:
                v = (a-b) if fn3==0 else (self.sx(a,32)>>(b&31))&MASK
            elif fn7 == 0x01:
                if   fn3==0: v=(sa*sb)&MASK
                elif fn3==1: v=((sa*sb)>>32)&MASK
                elif fn3==2: v=((sa*b)>>32)&MASK
                elif fn3==3: v=((a*b)>>32)&MASK
                # DIV (signed): div-by-zero → -1, INT_MIN/-1 → INT_MIN (overflow per spec),
                # else truncate toward zero (not Python's floor division).
                elif fn3==4: v = MASK if b == 0 else (0x80000000 if sa == -2**31 and sb == -1
                                                     else self.trunc_div(sa, sb) & MASK)
                # DIVU: div-by-zero → all-ones
                elif fn3==5: v = MASK if b == 0 else a // b
                # REM (signed): div-by-zero → dividend, INT_MIN%-1 → 0, else trunc-toward-zero rem
                elif fn3==6: v = a if b == 0 else (0 if sa == -2**31 and sb == -1
                                                   else self.trunc_rem(sa, sb) & MASK)
                # REMU: div-by-zero → dividend
                elif fn3==7: v = a if b == 0 else a % b
                else: return None
            else: return None
            wrd, wval = rd, v & MASK
        elif op == 0x13:  # OP-IMM
            a = r[rs1]
            v = [a+imm_i, a<<(imm_i&31), int(self.sx(a,32)<imm_i), int(a<(imm_i&MASK)),
                 a^(imm_i&MASK), None, a|(imm_i&MASK), a&(imm_i&MASK)][fn3]
            if fn3==5: v=(self.sx(a,32)>>(imm_i&31))&MASK if fn7&0x20 else a>>(imm_i&31)
            wrd, wval = rd, v & MASK
        elif op == 0x03:  # LOAD
            addr = (r[rs1] + imm_i) & MASK
            # fn3 low 2 bits: 0=byte, 1=half, 2=word → mask = (1<<(1<<fn3))-1 = 1, 3, 15
            mem_addr = addr
            mem_rmask = [1, 3, 15][fn3 & 3]
            v = [self.sx(self.rb(addr), 8) & MASK, self.sx(self.rhw(addr), 16) & MASK,
                 self.rw(addr), 0, self.rb(addr), self.rhw(addr)][fn3]
            # mem_rdata reports the raw loaded bytes (pre-sign-extension).
            mem_rdata = [self.rb(addr), self.rhw(addr), self.rw(addr),
                         0, self.rb(addr), self.rhw(addr)][fn3]
            wrd, wval = rd, v & MASK
        elif op == 0x23:  # STORE
            addr=(r[rs1]+imm_s)&MASK; mem_addr=addr
            if fn3==0: self.wb(addr,r[rs2]);  mem_wmask,mem_wdata=1, r[rs2]&0xFF
            elif fn3==1: self.whw(addr,r[rs2]); mem_wmask,mem_wdata=3, r[rs2]&0xFFFF
            elif fn3==2: self.ww(addr,r[rs2]);  mem_wmask,mem_wdata=15,r[rs2]
        elif op == 0x63:  # BRANCH
            a,b=r[rs1],r[rs2]; sa,sb=self.sx(a,32),self.sx(b,32)
            taken={0:a==b,1:a!=b,4:sa<sb,5:sa>=sb,6:a<b,7:a>=b}.get(fn3,False)
            if taken: npc=(pc+imm_b)&MASK
        elif op == 0x6F:  wrd,wval=rd,(pc+4)&MASK; npc=(pc+imm_j)&MASK  # JAL
        elif op == 0x67:  wrd,wval=rd,(pc+4)&MASK; npc=(r[rs1]+imm_i)&~1&MASK  # JALR
        elif op == 0x37:  wrd,wval=rd,imm_u&MASK   # LUI
        elif op == 0x17:  wrd,wval=rd,(pc+imm_u)&MASK  # AUIPC
        # MISC-MEM (FENCE/FENCE.I): treat as architectural NOP — this minimal
        # core has no cache/pipeline ordering hazards that a FENCE would resolve.
        elif op == 0x0F: pass
        # SYSTEM: only EBREAK is accepted. Previous version treated all 0x73
        # as NOP, which agreed with the Decoder's silent-default behavior and
        # masked any real CSR/ECALL/MRET divergence. Anything else is illegal
        # and returns None so the testbench flags it.
        elif op == 0x73:
            if instr != 0x00100073:
                return None
        else: return None

        if wrd: r[wrd]=wval
        r[0]=0; self.pc=npc; self.retired+=1
        return {'order':self.retired-1,'pc':pc,'npc':npc,'insn':instr,
                'rd':wrd,'rd_wdata':wval if wrd else 0,
                'rs1':rs1,'rs1_rdata':rs1_rdata_pre,
                'rs2':rs2,'rs2_rdata':rs2_rdata_pre,
                'mem_addr':mem_addr,'mem_rmask':mem_rmask,'mem_rdata':mem_rdata,
                'mem_wmask':mem_wmask,'mem_wdata':mem_wdata,
                # RVFI metadata the sim now also reports. The reference models
                # an M-mode-only RV32I core with no traps implemented; keep
                # these constants to catch any divergence where the CPU starts
                # reporting non-trivial values.
                'trap':0,'halt':0,'intr':0,'mode':3,'ixl':1}

if __name__ == '__main__':
    cpu = RV32IM()
    cpu.load_elf(sys.argv[1])
    max_insns = int(sys.argv[2]) if len(sys.argv)>2 else 10_000_000
    import json
    for _ in range(max_insns):
        r = cpu.step()
        if r is None: break
        print(json.dumps(r))
        if r['insn'] == 0x00100073: break
