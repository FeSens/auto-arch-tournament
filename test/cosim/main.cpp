#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <cstdint>
#include <cstring>
#include "Vcore.h"
#include "verilated.h"

struct ELF {
    std::vector<uint8_t> data;
    uint32_t entry = 0;
    void load(const char* path) {
        std::ifstream f(path, std::ios::binary);
        data.assign(std::istreambuf_iterator<char>(f), {});
        if (data.size() < 52) return;
        entry = *reinterpret_cast<uint32_t*>(&data[24]);
    }
    uint32_t phoff()     { return *reinterpret_cast<uint32_t*>(&data[28]); }
    uint16_t phentsize() { return *reinterpret_cast<uint16_t*>(&data[42]); }
    uint16_t phnum()     { return *reinterpret_cast<uint16_t*>(&data[44]); }
};

static constexpr uint32_t MEM_SIZE = 1u << 20;  // 1 MiB
static uint8_t imem[MEM_SIZE] = {};
static uint8_t dmem[MEM_SIZE] = {};
static bool oob_access = false;  // sticky: once set, final marker reports it

static bool in_uart_range(uint32_t a) { return (a & 0xFFF00000u) == 0x10000000u; }
static bool in_mem_range (uint32_t a) { return a < MEM_SIZE; }

// Benchmark-time MMIO markers. CoreMark's portme.c writes to BENCH_START
// from start_time() and BENCH_STOP from stop_time(); the sim records the
// cycle count at each write so run_fpga_eval can compute
// bench_cycles = stop - start, excluding init/CRC-printing overhead.
static constexpr uint32_t BENCH_START_ADDR = 0x10000100u;
static constexpr uint32_t BENCH_STOP_ADDR  = 0x10000104u;

uint32_t rw(uint8_t* m, uint32_t a) {
    a &= 0xFFFFC;
    return m[a]|(m[a+1]<<8)|(m[a+2]<<16)|(m[a+3]<<24);
}
void ww(uint8_t* m, uint32_t a, uint32_t v, uint8_t mask) {
    a &= 0xFFFFC;
    for(int i=0;i<4;i++) if((mask>>i)&1) m[a+i]=(v>>(i*8))&0xFF;
}

int main(int argc, char** argv) {
    if(argc < 2) { std::cerr << "usage: sim <elf> [maxcycles] [--bench]\n"; return 1; }
    uint64_t maxcycles = argc > 2 ? atoll(argv[2]) : 50000000ULL;
    // --bench: suppress per-retirement output; print only the final record at exit.
    // Use for performance measurement to avoid pipe-throttling on large runs.
    bool bench_mode = false;
    for (int i = 1; i < argc; i++) { if (std::strcmp(argv[i], "--bench") == 0) bench_mode = true; }

    ELF elf; elf.load(argv[1]);
    for(int i=0;i<elf.phnum();i++){
        uint32_t off    = elf.phoff() + i*elf.phentsize();
        uint32_t type   = *reinterpret_cast<uint32_t*>(&elf.data[off]);
        uint32_t foff   = *reinterpret_cast<uint32_t*>(&elf.data[off+4]);
        uint32_t vaddr  = *reinterpret_cast<uint32_t*>(&elf.data[off+8]);
        uint32_t filesz = *reinterpret_cast<uint32_t*>(&elf.data[off+16]);
        if(type==1 && vaddr < (1<<20)) {
            memcpy(imem+vaddr, elf.data.data()+foff, filesz);
            memcpy(dmem+vaddr, elf.data.data()+foff, filesz);
        }
    }

    Verilated::commandArgs(argc, argv);
    Vcore* top = new Vcore;
    top->reset = 1; top->clock = 0;
    // Zero-wait BRAM: the bus is always ready. Stall modeling lives in
    // test/cosim/vex_main.cpp (its --istall / --dstall flags) for the
    // VexRiscv apples-to-apples comparison.
    top->io_imemReady = 1;
    top->io_dmemReady = 1;
    for(int i=0;i<5;i++){top->clock=0;top->eval();top->clock=1;top->eval();}
    top->reset = 0;

    char bench_last[512] = {};
    bool hit_ebreak = false;
    // UART capture: writes to 0x10000000 go to stdout as characters, not dmem.
    // CoreMark's portme.c redirects ee_printf through this MMIO so the bench
    // driver can parse "CoreMark Size"/"ERROR!" banners for CRC validation.
    std::string uart_buf;
    uint64_t bench_start_cycle = 0, bench_stop_cycle = 0;
    bool     bench_start_set = false, bench_stop_set = false;
    for(uint64_t cycle=0; cycle<maxcycles; cycle++) {
        top->clock = 0;
        // Bounds checks: silent wraparound used to mask CPU effective-address bugs
        // (both sim and reference aliased identically, so cosim would still pass).
        // Flag OOB so the testbench reports it and returns non-zero.
        //   - imem: PC should always be in range; flag every fetch outside.
        //   - dmem read: ANY read outside [0, MEM_SIZE) is OOB — including
        //     the UART range, which is write-only. Reads from UART used to
        //     silently alias to dmem[addr & 0xFFFFC] and not flag oob_access,
        //     diverging from reference.py which DOES flag them. Now both agree:
        //     UART reads flag oob and return 0.
        //   - dmem write: UART range is allowed (TX); BENCH_START/STOP are
        //     allowed (markers); anything else outside dmem is OOB (handled
        //     in the post-clock write block below).
        if (!in_mem_range(top->io_imemAddr)) oob_access = true;
        top->io_imemData  = rw(imem, top->io_imemAddr);
        if (in_mem_range(top->io_dmemAddr)) {
            top->io_dmemRData = rw(dmem, top->io_dmemAddr);
        } else {
            top->io_dmemRData = 0;
            if (top->io_dmemREn) oob_access = true;
        }
        top->eval();
        top->clock = 1; top->eval();

        if(top->io_dmemWEn) {
            // MMIO UART at 0x10000000: capture to uart_buf, don't route to dmem
            // (a non-gated ww() would wrap 0x10000000 to dmem[0] and corrupt it).
            // BENCH_START/BENCH_STOP markers at 0x10000100 / 0x10000104: record
            // cycle counts so the bench harness can bracket the benchmark loop
            // and exclude CoreMark init/CRC-printing from the timing window.
            uint32_t addr = top->io_dmemAddr;
            if (addr == BENCH_START_ADDR) {
                if (!bench_start_set) { bench_start_cycle = cycle; bench_start_set = true; }
            } else if (addr == BENCH_STOP_ADDR) {
                // Last stop_time() call wins — CoreMark calls it once, but
                // tolerate multiple if a bench program re-times.
                bench_stop_cycle = cycle; bench_stop_set = true;
            } else if (in_uart_range(addr)) {
                for (int i = 0; i < 4; i++) {
                    if ((top->io_dmemWEn >> i) & 1) {
                        char c = (top->io_dmemWData >> (i * 8)) & 0xFF;
                        if (c) uart_buf.push_back(c);
                    }
                }
            } else if (in_mem_range(addr)) {
                ww(dmem, addr, top->io_dmemWData, top->io_dmemWEn);
            } else {
                // OOB write (neither dmem nor UART). Flag so testbench reports it.
                oob_access = true;
            }
        }

        if(top->io_rvfi_valid) {
            char buf[640];
            int n = snprintf(buf, sizeof(buf),
                   "{\"order\":%llu,\"cycle\":%llu,\"insn\":%u,\"pc_rdata\":%u,\"pc_wdata\":%u,"
                   "\"rd_addr\":%u,\"rd_wdata\":%u,"
                   "\"rs1_addr\":%u,\"rs1_rdata\":%u,"
                   "\"rs2_addr\":%u,\"rs2_rdata\":%u,"
                   "\"mem_addr\":%u,\"mem_rmask\":%u,\"mem_rdata\":%u,"
                   "\"mem_wmask\":%u,\"mem_wdata\":%u,"
                   "\"trap\":%u,\"halt\":%u,\"intr\":%u,\"mode\":%u,\"ixl\":%u}",
                (unsigned long long)top->io_rvfi_order,
                (unsigned long long)cycle,
                top->io_rvfi_insn, top->io_rvfi_pc_rdata, top->io_rvfi_pc_wdata,
                top->io_rvfi_rd_addr, top->io_rvfi_rd_wdata,
                top->io_rvfi_rs1_addr, top->io_rvfi_rs1_rdata,
                top->io_rvfi_rs2_addr, top->io_rvfi_rs2_rdata,
                top->io_rvfi_mem_addr, top->io_rvfi_mem_rmask, top->io_rvfi_mem_rdata,
                top->io_rvfi_mem_wmask, top->io_rvfi_mem_wdata,
                (unsigned)top->io_rvfi_trap,  (unsigned)top->io_rvfi_halt,
                (unsigned)top->io_rvfi_intr,  (unsigned)top->io_rvfi_mode,
                (unsigned)top->io_rvfi_ixl);
            (void)n;
            if (bench_mode) {
                strncpy(bench_last, buf, sizeof(bench_last)-1);
                if(top->io_rvfi_insn == 0x00100073) { hit_ebreak = true; break; }
            } else {
                puts(buf);
                fflush(stdout);
                if(top->io_rvfi_insn == 0x00100073) { hit_ebreak = true; break; }
            }
        }
    }
    if (bench_mode) {
        // Emit final record, plus an explicit completion marker. Consumers MUST
        // check "ebreak":true before trusting the cycle count — otherwise the
        // benchmark hit maxcycles without completing and the reading is invalid.
        if (bench_last[0]) puts(bench_last);
        // Escape backslash/quote/newline in uart_buf for JSON string safety.
        std::string esc;
        for (char c : uart_buf) {
            if (c == '\\' || c == '"') { esc.push_back('\\'); esc.push_back(c); }
            else if (c == '\n') { esc += "\\n"; }
            else if (c == '\r') { esc += "\\r"; }
            else if (c == '\t') { esc += "\\t"; }
            else if (c >= 0x20 && c < 0x7F) { esc.push_back(c); }
            // drop other non-printables silently
        }
        printf("{\"ebreak\":%s,\"maxcycles_hit\":%s,\"oob\":%s,"
               "\"bench_start_cycle\":%llu,\"bench_stop_cycle\":%llu,"
               "\"bench_bracketed\":%s,\"uart\":\"%s\"}\n",
               hit_ebreak ? "true" : "false",
               hit_ebreak ? "false" : "true",
               oob_access ? "true" : "false",
               (unsigned long long)bench_start_cycle,
               (unsigned long long)bench_stop_cycle,
               (bench_start_set && bench_stop_set) ? "true" : "false",
               esc.c_str());
    }
    delete top;
    // Non-zero exit if sim ran out of cycles OR an out-of-bounds memory
    // access occurred. OOB historically silently aliased to dmem[0] which
    // could mask CPU effective-address bugs — now it fails loud.
    if (!hit_ebreak) return 2;
    if (oob_access)  return 3;
    return 0;
}
