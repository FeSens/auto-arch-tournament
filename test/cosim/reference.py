#!/usr/bin/env python3
"""RV32IM reference interpreter for the cosim. Mirrors the DUT's trap
discipline so cosim traces stay aligned across illegal / misaligned
encodings.

Trap policy (matches rtl/decoder.sv default-illegal + rtl/ex_stage.sv +
rtl/mem_stage.sv misalign traps):

  - Reserved R-type:        funct7=0x20 with fn3 ∈ {1,2,3,4,6,7}
  - Reserved OP-IMM shifts: SLLI/SRLI/SRAI with disallowed funct7
  - Reserved LOAD funct3:   3, 6, 7
  - Reserved STORE funct3:  3..7
  - Reserved BRANCH funct3: 2, 3
  - JALR funct3 != 0
  - Non-EBREAK SYSTEM:      ECALL, CSR ops, MRET, …
  - Unknown opcode (AMO etc.)
  - Misaligned LH/LHU/LW/SH/SW
  - Misaligned BRANCH (taken) / JAL / JALR target

On trap the retirement is reported with rvfi_trap=1, rd_addr=0,
rd_wdata=0, mem_*=0, npc=pc+4. The DUT's mem_stage / ex_stage match
this on the same encodings.

Modifications to this file require explicit user approval."""
import struct, sys
from dataclasses import dataclass, field
from typing import Optional

XLEN = 32
MASK = (1 << XLEN) - 1
MEM_BYTES = 1 << 20  # 1 MiB

# MMIO UART. Writes are consumed by the testbench. Reads are undefined
# and are flagged as oob_access (sticky); main.cpp does the same.
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

    def _retire(self, *, pc, npc, instr, trap=0,
                wrd=0, wval=0, rs1=0, rs2=0,
                rs1_rdata_pre=0, rs2_rdata_pre=0,
                mem_addr=0, mem_rmask=0, mem_rdata=0,
                mem_wmask=0, mem_wdata=0):
        """Centralized retirement record. On trap=1 we zero out the
        write-side fields and force npc = pc + 4 so the trace stays in
        lockstep with the DUT (which suppresses redirects + reg/mem
        commits on misalign / illegal)."""
        if trap:
            wrd = wval = 0
            mem_addr = mem_rmask = mem_wmask = 0
            mem_rdata = mem_wdata = 0
            npc = (pc + 4) & MASK
        if wrd:
            self.regs[wrd] = wval
        self.regs[0] = 0
        self.pc = npc
        out = {
            'order': self.retired, 'pc': pc, 'npc': npc, 'insn': instr,
            'rd': wrd, 'rd_wdata': wval if wrd else 0,
            'rs1': rs1, 'rs1_rdata': rs1_rdata_pre,
            'rs2': rs2, 'rs2_rdata': rs2_rdata_pre,
            'mem_addr': mem_addr, 'mem_rmask': mem_rmask, 'mem_rdata': mem_rdata,
            'mem_wmask': mem_wmask, 'mem_wdata': mem_wdata,
            'trap': trap, 'halt': 0, 'intr': 0, 'mode': 3, 'ixl': 1,
        }
        self.retired += 1
        return out

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

        r = self.regs
        pc = self.pc
        npc = (pc + 4) & MASK
        # Snapshot rs1/rs2 BEFORE writing rd — RVFI requires reporting the
        # values the instruction consumed.
        rs1_rdata_pre = self.regs[rs1]
        rs2_rdata_pre = self.regs[rs2]

        # Default kwargs for _retire on trap (no commit, no mem op).
        trap_kwargs = dict(
            pc=pc, npc=npc, instr=instr,
            rs1=rs1, rs2=rs2,
            rs1_rdata_pre=rs1_rdata_pre, rs2_rdata_pre=rs2_rdata_pre,
        )

        if op == 0x33:  # R-type
            a, b = r[rs1], r[rs2]
            sa, sb = self.sx(a, 32), self.sx(b, 32)
            valid = (
                fn7 == 0x00 or
                (fn7 == 0x20 and fn3 in (0, 5)) or
                fn7 == 0x01
            )
            if not valid:
                return self._retire(**trap_kwargs, trap=1)
            if fn7 == 0x00:
                v = [a+b, a<<(b&31), int(sa<sb), int(a<b),
                     a^b, a>>(b&31), a|b, a&b][fn3]
            elif fn7 == 0x20:
                v = (a-b) if fn3 == 0 else (self.sx(a, 32) >> (b & 31)) & MASK
            else:  # fn7 == 0x01 (M-extension)
                if   fn3 == 0: v = (sa * sb) & MASK
                elif fn3 == 1: v = ((sa * sb) >> 32) & MASK
                elif fn3 == 2: v = ((sa * b) >> 32) & MASK
                elif fn3 == 3: v = ((a * b) >> 32) & MASK
                elif fn3 == 4: v = MASK if b == 0 else (
                    0x80000000 if sa == -2**31 and sb == -1
                    else self.trunc_div(sa, sb) & MASK)
                elif fn3 == 5: v = MASK if b == 0 else a // b
                elif fn3 == 6: v = a if b == 0 else (
                    0 if sa == -2**31 and sb == -1
                    else self.trunc_rem(sa, sb) & MASK)
                else:          v = a if b == 0 else a % b
            return self._retire(**trap_kwargs, wrd=rd, wval=v & MASK)

        if op == 0x13:  # OP-IMM
            a = r[rs1]
            # Shift funct3 (1, 5) requires specific funct7 values.
            if fn3 == 1 and fn7 != 0x00:
                return self._retire(**trap_kwargs, trap=1)   # SLLI must have funct7=0
            if fn3 == 5 and fn7 not in (0x00, 0x20):
                return self._retire(**trap_kwargs, trap=1)   # SRLI/SRAI funct7 fixed
            if fn3 == 0: v = (a + imm_i) & MASK
            elif fn3 == 1: v = (a << (imm_i & 31)) & MASK
            elif fn3 == 2: v = int(self.sx(a, 32) < imm_i)
            elif fn3 == 3: v = int(a < (imm_i & MASK))
            elif fn3 == 4: v = (a ^ (imm_i & MASK)) & MASK
            elif fn3 == 5:
                v = (self.sx(a, 32) >> (imm_i & 31)) & MASK if (fn7 & 0x20) \
                    else a >> (imm_i & 31)
            elif fn3 == 6: v = (a | (imm_i & MASK)) & MASK
            else:          v = (a & (imm_i & MASK)) & MASK
            return self._retire(**trap_kwargs, wrd=rd, wval=v & MASK)

        if op == 0x03:  # LOAD
            if fn3 not in (0, 1, 2, 4, 5):
                return self._retire(**trap_kwargs, trap=1)
            addr = (r[rs1] + imm_i) & MASK
            # Misalign trap (mem_stage's policy): word needs [1:0]==0,
            # halfword needs [0]==0, byte never misaligns.
            if (fn3 in (2,)         and addr & 0x3) or \
               (fn3 in (1, 5)       and addr & 0x1):
                return self._retire(**trap_kwargs, trap=1)
            mem_addr = addr
            mem_rmask = [1, 3, 15][fn3 & 3]   # byte/half/word size mask
            if   fn3 == 0: v = self.sx(self.rb(addr), 8)  & MASK
            elif fn3 == 1: v = self.sx(self.rhw(addr), 16) & MASK
            elif fn3 == 2: v = self.rw(addr)
            elif fn3 == 4: v = self.rb(addr)
            else:          v = self.rhw(addr)
            mem_rdata = [self.rb(addr), self.rhw(addr), self.rw(addr),
                         0, self.rb(addr), self.rhw(addr)][fn3]
            return self._retire(**trap_kwargs, wrd=rd, wval=v & MASK,
                                mem_addr=mem_addr, mem_rmask=mem_rmask,
                                mem_rdata=mem_rdata)

        if op == 0x23:  # STORE
            if fn3 not in (0, 1, 2):
                return self._retire(**trap_kwargs, trap=1)
            addr = (r[rs1] + imm_s) & MASK
            if (fn3 == 2 and addr & 0x3) or (fn3 == 1 and addr & 0x1):
                return self._retire(**trap_kwargs, trap=1)
            mem_addr = addr
            if fn3 == 0:
                self.wb(addr, r[rs2])
                mem_wmask, mem_wdata = 1, r[rs2] & 0xFF
            elif fn3 == 1:
                self.whw(addr, r[rs2])
                mem_wmask, mem_wdata = 3, r[rs2] & 0xFFFF
            else:
                self.ww(addr, r[rs2])
                mem_wmask, mem_wdata = 15, r[rs2]
            return self._retire(**trap_kwargs,
                                mem_addr=mem_addr,
                                mem_wmask=mem_wmask, mem_wdata=mem_wdata)

        if op == 0x63:  # BRANCH
            if fn3 in (2, 3):
                return self._retire(**trap_kwargs, trap=1)
            a, b = r[rs1], r[rs2]
            sa, sb = self.sx(a, 32), self.sx(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb,
                     6: a < b,  7: a >= b}.get(fn3, False)
            if taken:
                target = (pc + imm_b) & MASK
                if target & 0x3:
                    return self._retire(**trap_kwargs, trap=1)
                trap_kwargs['npc'] = target
            return self._retire(**trap_kwargs)

        if op == 0x6F:  # JAL
            target = (pc + imm_j) & MASK
            if target & 0x3:
                return self._retire(**trap_kwargs, trap=1)
            trap_kwargs['npc'] = target
            return self._retire(**trap_kwargs, wrd=rd, wval=(pc + 4) & MASK)

        if op == 0x67:  # JALR
            if fn3 != 0:
                return self._retire(**trap_kwargs, trap=1)
            target = (r[rs1] + imm_i) & ~1 & MASK
            if target & 0x3:
                return self._retire(**trap_kwargs, trap=1)
            trap_kwargs['npc'] = target
            return self._retire(**trap_kwargs, wrd=rd, wval=(pc + 4) & MASK)

        if op == 0x37:  # LUI
            return self._retire(**trap_kwargs, wrd=rd, wval=imm_u & MASK)

        if op == 0x17:  # AUIPC
            return self._retire(**trap_kwargs, wrd=rd, wval=(pc + imm_u) & MASK)

        if op == 0x0F:  # MISC-MEM (FENCE / FENCE.I) — architectural NOP
            return self._retire(**trap_kwargs)

        if op == 0x73:  # SYSTEM
            if instr == 0x00100073:
                return self._retire(**trap_kwargs)
            return self._retire(**trap_kwargs, trap=1)

        # Unknown opcode (AMO 0x2F, etc.) — DUT decoder default-illegal.
        return self._retire(**trap_kwargs, trap=1)


if __name__ == '__main__':
    cpu = RV32IM()
    cpu.load_elf(sys.argv[1])
    max_insns = int(sys.argv[2]) if len(sys.argv) > 2 else 10_000_000
    import json
    for _ in range(max_insns):
        r = cpu.step()
        if r is None:
            break
        print(json.dumps(r))
        if r['insn'] == 0x00100073:
            break
