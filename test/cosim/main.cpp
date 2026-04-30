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

// VexRiscv-style random bus backpressure model (regression/main.cpp:2079).
// xorshift7 LFSR; accept request when (state & 0x7F) < 100 (~78% accept,
// ~22% stall). Replicating exactly so CoreMark/MHz numbers from this
// cosim are directly comparable to VexRiscv's published "full no cache,
// 2.30" — which is measured under iStall+dStall enabled.
static uint32_t lfsr_state_main = 0xDEADBEEFu;
static bool bus_accepts_main() {
    lfsr_state_main ^= lfsr_state_main << 13;
    lfsr_state_main ^= lfsr_state_main >> 17;
    lfsr_state_main ^= lfsr_state_main << 5;
    return (lfsr_state_main & 0x7Fu) < 100u;
}

int main(int argc, char** argv) {
    if(argc < 2) {
        std::cerr << "usage: sim <elf> [maxcycles] [--bench] [--istall] [--dstall] [--seed N]\n";
        return 1;
    }
    uint64_t maxcycles = argc > 2 ? atoll(argv[2]) : 50000000ULL;
    // --bench:  suppress per-retirement output; print only the final record.
    // --istall: random ~22% imem-bus backpressure (VexRiscv-style).
    // --dstall: same on dmem bus. The orchestrator's fitness eval
    //           (tools/eval/fpga.py:run_coremark_ipc) passes BOTH so the
    //           CoreMark/MHz number we score against matches VexRiscv's
    //           published methodology rather than a zero-wait fantasy bus.
    bool bench_mode = false;
    bool istall = false;
    bool dstall = false;
    for (int i = 1; i < argc; i++) {
        if      (std::strcmp(argv[i], "--bench")  == 0) bench_mode = true;
        else if (std::strcmp(argv[i], "--istall") == 0) istall     = true;
        else if (std::strcmp(argv[i], "--dstall") == 0) dstall     = true;
        else if (std::strcmp(argv[i], "--seed")   == 0 && i + 1 < argc)
            lfsr_state_main = (uint32_t)atoll(argv[++i]);
    }

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
        // Bus backpressure. Same VexRiscv-style ~22% accept-fail rate on
        // both imem and dmem when the corresponding flag is on. Drives 1
        // (zero-wait) by default so existing selftest cosim runs aren't
        // slowed down by unrelated stalls.
        top->io_imemReady = istall ? bus_accepts_main() : 1;
        top->io_dmemReady = dstall ? bus_accepts_main() : 1;
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
        //     in the dmem-write block below — kept BEFORE the clock posedge so
        //     a STORE that's accepted on the cycle dmem_ready transitions
        //     0->1 doesn't disappear when EX/MEM advances at posedge).
        if (!in_mem_range(top->io_imemAddr)) oob_access = true;
        top->io_imemData  = rw(imem, top->io_imemAddr);
        if (in_mem_range(top->io_dmemAddr)) {
            top->io_dmemRData = rw(dmem, top->io_dmemAddr);
        } else {
            top->io_dmemRData = 0;
            if (top->io_dmemREn) oob_access = true;
        }
        top->eval();

        // Process dmem writes BEFORE the clock posedge — see the matching
        // commit on test/cosim/vex_main.cpp for the timing-bug rationale:
        // post-posedge sampling drops STOREs that get accepted on the
        // cycle dmem_ready transitions 0 -> 1.
        if(top->io_dmemWEn && top->io_dmemReady) {
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

        top->clock = 1; top->eval();

        // Drain channel 0 then channel 1 (NRET=2 contract). For V0
        // single-issue, channel 1's valid is always 0, so the JSON stream
        // is byte-identical to the pre-NRET=2 baseline.
        auto emit = [&](uint8_t  v,
                        uint64_t order,
                        uint32_t insn,
                        uint32_t pc_rdata, uint32_t pc_wdata,
                        uint8_t  rd_addr,  uint32_t rd_wdata,
                        uint8_t  rs1_addr, uint32_t rs1_rdata,
                        uint8_t  rs2_addr, uint32_t rs2_rdata,
                        uint32_t mem_addr,
                        uint8_t  mem_rmask, uint32_t mem_rdata,
                        uint8_t  mem_wmask, uint32_t mem_wdata,
                        uint8_t  trap, uint8_t halt, uint8_t intr,
                        uint8_t  mode, uint8_t ixl) -> bool {
            if (!v) return false;
            char buf[640];
            snprintf(buf, sizeof(buf),
                "{\"order\":%llu,\"cycle\":%llu,\"insn\":%u,\"pc_rdata\":%u,\"pc_wdata\":%u,"
                "\"rd_addr\":%u,\"rd_wdata\":%u,"
                "\"rs1_addr\":%u,\"rs1_rdata\":%u,"
                "\"rs2_addr\":%u,\"rs2_rdata\":%u,"
                "\"mem_addr\":%u,\"mem_rmask\":%u,\"mem_rdata\":%u,"
                "\"mem_wmask\":%u,\"mem_wdata\":%u,"
                "\"trap\":%u,\"halt\":%u,\"intr\":%u,\"mode\":%u,\"ixl\":%u}",
                (unsigned long long)order,
                (unsigned long long)cycle,
                insn, pc_rdata, pc_wdata,
                rd_addr, rd_wdata,
                rs1_addr, rs1_rdata,
                rs2_addr, rs2_rdata,
                mem_addr, mem_rmask, mem_rdata,
                mem_wmask, mem_wdata,
                (unsigned)trap, (unsigned)halt, (unsigned)intr,
                (unsigned)mode, (unsigned)ixl);
            if (bench_mode) {
                strncpy(bench_last, buf, sizeof(bench_last)-1);
                if (insn == 0x00100073) { hit_ebreak = true; return true; }
            } else {
                puts(buf);
                fflush(stdout);
                if (insn == 0x00100073) { hit_ebreak = true; return true; }
            }
            return false;
        };

        if (emit(top->io_rvfi_valid_0, top->io_rvfi_order_0, top->io_rvfi_insn_0,
                 top->io_rvfi_pc_rdata_0, top->io_rvfi_pc_wdata_0,
                 top->io_rvfi_rd_addr_0, top->io_rvfi_rd_wdata_0,
                 top->io_rvfi_rs1_addr_0, top->io_rvfi_rs1_rdata_0,
                 top->io_rvfi_rs2_addr_0, top->io_rvfi_rs2_rdata_0,
                 top->io_rvfi_mem_addr_0,
                 top->io_rvfi_mem_rmask_0, top->io_rvfi_mem_rdata_0,
                 top->io_rvfi_mem_wmask_0, top->io_rvfi_mem_wdata_0,
                 top->io_rvfi_trap_0, top->io_rvfi_halt_0, top->io_rvfi_intr_0,
                 top->io_rvfi_mode_0, top->io_rvfi_ixl_0)) break;
        if (emit(top->io_rvfi_valid_1, top->io_rvfi_order_1, top->io_rvfi_insn_1,
                 top->io_rvfi_pc_rdata_1, top->io_rvfi_pc_wdata_1,
                 top->io_rvfi_rd_addr_1, top->io_rvfi_rd_wdata_1,
                 top->io_rvfi_rs1_addr_1, top->io_rvfi_rs1_rdata_1,
                 top->io_rvfi_rs2_addr_1, top->io_rvfi_rs2_rdata_1,
                 top->io_rvfi_mem_addr_1,
                 top->io_rvfi_mem_rmask_1, top->io_rvfi_mem_rdata_1,
                 top->io_rvfi_mem_wmask_1, top->io_rvfi_mem_wdata_1,
                 top->io_rvfi_trap_1, top->io_rvfi_halt_1, top->io_rvfi_intr_1,
                 top->io_rvfi_mode_1, top->io_rvfi_ixl_1)) break;
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
