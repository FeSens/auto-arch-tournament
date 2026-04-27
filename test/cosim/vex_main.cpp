// test/cosim/vex_main.cpp
//
// Sister cosim harness for running VexRiscv-style RAW binaries against
// our `core`. Used for the head-to-head CoreMark/MHz comparison against
// VexRiscv's published "full no cache, 2.30 CoreMark/MHz" — runs the
// SAME pre-compiled binary VexRiscv runs in its regression
// (src/test/resources/bin/coremark_rv32im.bin), so the only variable is
// our microarchitecture vs. theirs.
//
// Memory map mimics VexRiscv's regression:
//   [0x00000000, 0x00000008)   bootstub: lui ra,0x80000; jalr x0, ra, 0
//   [0x80000000, 0x80100000)   1 MiB code+data (the VexRiscv .bin lives here)
//   0xF0010000 (write)         UART TX (one byte per word)
//   0xF0010004 (read)          UART status, returns ~0
//   0xF00FFF20 (write 0)       pass / done
//   0xF00FFF20 (write !=0)     fail
//   0xF00FFF40 (read)          mTime[31:0]   (cycle counter low)
//   0xF00FFF44 (read)          mTime[63:32]  (cycle counter high)
//
// Output: same JSON-ish marker as test/cosim/main.cpp's --bench mode
// (last line) so the wrapping Python harness can parse uniformly.
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include "Vcore.h"
#include "verilated.h"

// Memory regions
static constexpr uint32_t HIGH_BASE = 0x80000000u;
static constexpr uint32_t HIGH_SIZE = 1u << 20;          // 1 MiB
static uint8_t high_mem[HIGH_SIZE] = {};

// Boot stub at address 0: lui ra, 0x80000; jalr x0, ra, 0
static const uint32_t BOOT_LUI  = 0x800000B7u;  // lui x1, 0x80000
static const uint32_t BOOT_JALR = 0x00008067u;  // jalr x0, x1, 0

// VexRiscv MMIO addresses (per VexRiscv/src/test/cpp/regression/main.cpp).
// 0xF0010000 and 0xF00FFF00 are BOTH valid putchar in their reference;
// some configs write to one, some to the other.
static constexpr uint32_t UART_TX_ADDR    = 0xF0010000u;
static constexpr uint32_t UART_TX_ALT     = 0xF00FFF00u;
static constexpr uint32_t UART_STATUS_ADDR= 0xF0010004u;
static constexpr uint32_t PASS_FAIL_ADDR  = 0xF00FFF20u;
static constexpr uint32_t MTIME_LO_ADDR   = 0xF00FFF40u;
static constexpr uint32_t MTIME_HI_ADDR   = 0xF00FFF44u;
static constexpr bool     IN_VEX_MMIO     = true;  // sentinel for clarity

static bool oob_access = false;
static bool sim_done   = false;
static int  exit_code  = 0;

static uint32_t read_word(uint32_t addr, uint64_t mtime) {
    addr &= 0xFFFFFFFCu;  // word align (matches our DUT's mem_addr)
    if (addr < 8) {
        // Boot stub.
        if (addr == 0) return BOOT_LUI;
        if (addr == 4) return BOOT_JALR;
    }
    if (addr >= HIGH_BASE && addr < HIGH_BASE + HIGH_SIZE) {
        uint32_t off = addr - HIGH_BASE;
        return high_mem[off] | (high_mem[off+1] << 8) |
               (high_mem[off+2] << 16) | (high_mem[off+3] << 24);
    }
    if (addr == MTIME_LO_ADDR)    return (uint32_t)(mtime & 0xFFFFFFFFu);
    if (addr == MTIME_HI_ADDR)    return (uint32_t)(mtime >> 32);
    if (addr == UART_STATUS_ADDR) return ~0u;          // matches VexRiscv ref
    // Anything else: undefined → flag oob and return 0.
    oob_access = true;
    return 0;
}

static void write_bytes(uint32_t addr, uint32_t wdata, uint8_t wmask,
                        std::string& uart_buf) {
    addr &= 0xFFFFFFFCu;
    // High memory write: just byte-mask in.
    if (addr >= HIGH_BASE && addr < HIGH_BASE + HIGH_SIZE) {
        uint32_t off = addr - HIGH_BASE;
        for (int i = 0; i < 4; i++) {
            if ((wmask >> i) & 1) high_mem[off + i] = (wdata >> (i * 8)) & 0xFF;
        }
        return;
    }
    // UART TX (either of the two VexRiscv putchar addresses).
    if (addr == UART_TX_ADDR || addr == UART_TX_ALT) {
        for (int i = 0; i < 4; i++) {
            if ((wmask >> i) & 1) {
                char c = (wdata >> (i * 8)) & 0xFF;
                if (c) uart_buf.push_back(c);
            }
        }
        return;
    }
    // Pass/fail marker.
    if (addr == PASS_FAIL_ADDR) {
        sim_done = true;
        exit_code = (wdata == 0) ? 0 : 1;
        return;
    }
    // Other VexRiscv MMIO we don't model — drop silently.
    if ((addr & 0xFFFFF000u) == 0xF00FF000u) return;
    if ((addr & 0xFFFFF000u) == 0xF0010000u) return;
    // Genuine OOB write.
    oob_access = true;
}

// VexRiscv's regression (src/test/cpp/regression/main.cpp:2079) gates each
// IBus / DBus accept by `VL_RANDOM_I_WIDTH(7) < 100`, i.e. accept when a
// random 7-bit value is below 100/128 ≈ 78%. So bus stall fires ~22% of
// the time per cycle. Replicating that exactly so our CoreMark/MHz
// number can be compared apples-to-apples with VexRiscv's published
// "full no cache, 2.30" (which was measured under this stall model).
static uint32_t lfsr_state = 0xDEADBEEFu;
static bool bus_accepts() {
    // Tiny xorshift7 — just needs to look uniform-enough on the 7-bit
    // window; the determinism makes runs reproducible.
    lfsr_state ^= lfsr_state << 13;
    lfsr_state ^= lfsr_state >> 17;
    lfsr_state ^= lfsr_state << 5;
    return (lfsr_state & 0x7Fu) < 100u;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: vex_sim <coremark_rv32im.bin> [maxcycles] "
                     "[--istall] [--dstall] [--seed N]\n";
        return 1;
    }
    uint64_t maxcycles = argc > 2 ? std::stoull(argv[2]) : 200000000ULL;
    bool istall = false, dstall = false;
    for (int i = 3; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--istall") istall = true;
        else if (a == "--dstall") dstall = true;
        else if (a == "--seed" && i + 1 < argc) {
            lfsr_state = (uint32_t)std::stoul(argv[++i]);
        }
    }

    // Load the raw binary into high_mem[0..size-1].
    std::ifstream f(argv[1], std::ios::binary);
    if (!f) { std::cerr << "cannot open " << argv[1] << "\n"; return 1; }
    f.read((char*)high_mem, HIGH_SIZE);
    std::streamsize loaded = f.gcount();
    if (loaded <= 0) { std::cerr << "empty .bin\n"; return 1; }

    Verilated::commandArgs(argc, argv);
    Vcore* top = new Vcore;
    top->reset = 1; top->clock = 0;
    top->io_imemReady = 1;
    top->io_dmemReady = 1;
    for (int i = 0; i < 5; i++) {
        top->clock = 0; top->eval();
        top->clock = 1; top->eval();
    }
    top->reset = 0;

    std::string uart_buf;
    uint64_t mtime = 0;        // cycle counter exposed via 0xF00FFF40/44

    for (uint64_t cycle = 0; cycle < maxcycles; cycle++) {
        top->clock = 0;

        // Bus backpressure. Same accept rate VexRiscv uses
        // (random[6:0] < 100 → ~78% accept ≈ 22% stall). Roll independently
        // for imem and dmem each cycle when the corresponding flag is on.
        top->io_imemReady = istall ? bus_accepts() : 1;
        top->io_dmemReady = dstall ? bus_accepts() : 1;

        // Drive imem data (read regardless of ready — when ready=0, the
        // pipeline's hazard_unit drops it and inserts a NOP).
        top->io_imemData = read_word(top->io_imemAddr, mtime);
        if (top->io_dmemREn && getenv("VEX_TRACE_LD")) {
            fprintf(stderr, "[cyc %llu] LD addr=0x%08x ready=%u rdata_will_be=0x%08x\n",
                    (unsigned long long)mtime,
                    top->io_dmemAddr, (unsigned)top->io_dmemReady,
                    (top->io_dmemAddr >= HIGH_BASE && top->io_dmemAddr < HIGH_BASE + HIGH_SIZE) ?
                      read_word(top->io_dmemAddr, mtime) : 0);
        }

        // Drive dmem read. Same memory model.
        if (top->io_dmemAddr >= HIGH_BASE && top->io_dmemAddr < HIGH_BASE + HIGH_SIZE) {
            top->io_dmemRData = read_word(top->io_dmemAddr, mtime);
        } else if (top->io_dmemAddr == MTIME_LO_ADDR) {
            top->io_dmemRData = (uint32_t)(mtime & 0xFFFFFFFFu);
        } else if (top->io_dmemAddr == MTIME_HI_ADDR) {
            top->io_dmemRData = (uint32_t)(mtime >> 32);
        } else if (top->io_dmemAddr == UART_STATUS_ADDR) {
            top->io_dmemRData = ~0u;
        } else if ((top->io_dmemAddr & 0xFFFFF000u) == 0xF00FF000u
                || (top->io_dmemAddr & 0xFFFFF000u) == 0xF0010000u) {
            // Some other MMIO read in the VexRiscv map (mtime, debug, etc.)
            // — return 0 deterministically rather than flagging oob.
            top->io_dmemRData = 0;
        } else if (top->io_dmemAddr < 8) {
            // Boot stub region — let read_word handle it.
            top->io_dmemRData = read_word(top->io_dmemAddr, mtime);
        } else {
            top->io_dmemRData = 0;
            if (top->io_dmemREn) oob_access = true;
        }

        top->eval();

        // Process dmem writes BEFORE the clock posedge, while the cycle's
        // signals still reflect the in-flight STORE in EX/MEM. If we wait
        // until after the posedge, a STORE that gets accepted on the
        // very cycle dmem_ready transitions 0 -> 1 disappears: EX/MEM
        // advances to the NEXT instruction at the posedge, dmem_wen
        // drops, and the write is silently lost. (No-stall mode catches
        // STORE on the *previous* iter's post-posedge check; with stalls
        // that timing breaks.)
        if (top->io_dmemWEn && top->io_dmemReady) {
            if (getenv("VEX_TRACE_WR")) {
                fprintf(stderr, "[cyc %llu] WR addr=0x%08x mask=0x%x data=0x%08x\n",
                        (unsigned long long)mtime,
                        top->io_dmemAddr, (unsigned)top->io_dmemWEn,
                        top->io_dmemWData);
            }
            write_bytes(top->io_dmemAddr, top->io_dmemWData,
                        top->io_dmemWEn, uart_buf);
        }

        top->clock = 1; top->eval();
        mtime++;  // one tick per simulated cycle

        if (top->io_rvfi_valid && getenv("VEX_TRACE_RET")) {
            fprintf(stderr, "[cyc %llu] RET pc=0x%08x insn=0x%08x trap=%u rd=%u rd_wdata=0x%08x\n",
                    (unsigned long long)mtime,
                    top->io_rvfi_pc_rdata, top->io_rvfi_insn,
                    (unsigned)top->io_rvfi_trap,
                    (unsigned)top->io_rvfi_rd_addr, top->io_rvfi_rd_wdata);
        }
        if (sim_done) {
            if (getenv("VEX_TRACE_WR") || getenv("VEX_TRACE_RET"))
                fprintf(stderr, "[cyc %llu] sim_done via PASS_FAIL_ADDR (exit_code=%d)\n",
                        (unsigned long long)mtime, exit_code);
            break;
        }
        if (top->io_rvfi_valid && top->io_rvfi_insn == 0x00100073) {
            sim_done = true;
            if (getenv("VEX_TRACE_WR") || getenv("VEX_TRACE_RET"))
                fprintf(stderr, "[cyc %llu] sim_done via ebreak\n",
                        (unsigned long long)mtime);
            break;
        }
    }

    // Escape UART for JSON.
    std::string esc;
    for (char c : uart_buf) {
        if (c == '\\' || c == '"') { esc.push_back('\\'); esc.push_back(c); }
        else if (c == '\n') esc += "\\n";
        else if (c == '\r') esc += "\\r";
        else if (c == '\t') esc += "\\t";
        else if (c >= 0x20 && c < 0x7F) esc.push_back(c);
    }
    printf("{\"sim_done\":%s,\"exit_code\":%d,\"oob\":%s,"
           "\"cycles\":%llu,\"uart\":\"%s\"}\n",
           sim_done   ? "true" : "false", exit_code,
           oob_access ? "true" : "false",
           (unsigned long long)mtime, esc.c_str());

    delete top;
    return sim_done ? exit_code : 2;
}
