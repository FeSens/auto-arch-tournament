// Stage 2 reference-core simulator: runs a bench ELF (CoreMark or a held-out
// kernel) on an open-source core and prints the same final JSON marker as
// test/cosim/main.cpp --bench, so tools/eval/fpga.py-style parsing applies.
//
// Same as the harness simulator: 1 MiB memory image loaded from the ELF's
// PT_LOAD segments, the same xorshift bus-backpressure model and seed
// (--istall/--dstall, about 22% of cycles stalled, imem drawn before dmem
// each cycle), UART capture at 0x10000000, BENCH_START/STOP markers at
// 0x10000100/0x10000104 (cycle of the accepted write), out-of-range accesses
// flagged as oob.
//
// Different from the harness simulator, because reference cores have their
// own buses: each core sits in a ref_top_<core>.sv adapter that turns its bus
// into one request per port per cycle (address valid with io_*Req, accepted
// when io_*Ready). The read data for an accepted request is returned on the
// next cycle (synchronous memory, which these cores are designed for); the
// harness's agent cores read combinationally instead. Completion is the
// first accepted fetch of crt0's ebreak after the BENCH_STOP write, or of an
// address outside memory (the trap vector, for a core that runs the ebreak
// from its instruction cache), or 200k cycles with no bus access (a core whose
// ebreak enters debug halt); reference cores have no common RVFI port. The
// score only uses the BENCH_START/STOP cycles, so the end rule only bounds
// the run; an early end would fail the UART validation. A core whose reset PC is not the ELF entry
// fetches "jalr x0, 0(x0)" at its reset PC once, before the timed window.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>
#include "Vref_top.h"
#include "verilated.h"

static constexpr uint32_t MEM_SIZE = 1u << 20;
static uint8_t mem[MEM_SIZE] = {};
static bool oob = false;
static constexpr uint32_t BENCH_START_ADDR = 0x10000100u;
static constexpr uint32_t BENCH_STOP_ADDR = 0x10000104u;
static bool in_uart(uint32_t a) { return (a & 0xFFF00000u) == 0x10000000u; }
static bool in_mem(uint32_t a) { return a < MEM_SIZE; }
static uint32_t rw(uint32_t a) {
    a &= 0xFFFFC;
    return mem[a] | (mem[a + 1] << 8) | (mem[a + 2] << 16) | ((uint32_t)mem[a + 3] << 24);
}
static void ww(uint32_t a, uint32_t v, uint8_t m) {
    a &= 0xFFFFC;
    for (int i = 0; i < 4; i++) if ((m >> i) & 1) mem[a + i] = (v >> (i * 8)) & 0xFF;
}
static uint32_t lfsr = 0xDEADBEEFu;
static bool accepts() {
    lfsr ^= lfsr << 13; lfsr ^= lfsr >> 17; lfsr ^= lfsr << 5;
    return (lfsr & 0x7Fu) < 100u;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: ref_sim <elf> [maxcycles] [--istall] [--dstall] [--reset-pc HEX]\n"); return 1; }
    uint64_t maxcycles = argc > 2 && argv[2][0] != '-' ? atoll(argv[2]) : 50000000ULL;
    bool istall = false, dstall = false;
    uint32_t reset_pc = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--istall")) istall = true;
        else if (!strcmp(argv[i], "--dstall")) dstall = true;
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) lfsr = (uint32_t)atoll(argv[++i]);
        else if (!strcmp(argv[i], "--reset-pc") && i + 1 < argc) reset_pc = strtoul(argv[++i], nullptr, 16);
    }
    std::ifstream f(argv[1], std::ios::binary);
    std::vector<uint8_t> e((std::istreambuf_iterator<char>(f)), {});
    uint32_t entry = *(uint32_t*)&e[24], phoff = *(uint32_t*)&e[28];
    uint16_t phentsize = *(uint16_t*)&e[42], phnum = *(uint16_t*)&e[44];
    for (int i = 0; i < phnum; i++) {
        uint8_t* p = &e[phoff + i * phentsize];
        uint32_t type = *(uint32_t*)p, foff = *(uint32_t*)(p + 4), vaddr = *(uint32_t*)(p + 8), filesz = *(uint32_t*)(p + 16);
        if (type == 1 && vaddr < MEM_SIZE) memcpy(mem + vaddr, e.data() + foff, filesz);
    }
    uint32_t ebreak_pc = entry;
    while (rw(ebreak_pc) != 0x00100073u && ebreak_pc < entry + 64) ebreak_pc += 4;
    bool trampoline = (reset_pc & ~3u) != entry;

    Verilated::commandArgs(argc, argv);
    Vref_top* top = new Vref_top;
    top->reset = 1; top->clock = 0; top->io_imemReady = 1; top->io_dmemReady = 1;
    for (int i = 0; i < 5; i++) { top->clock = 0; top->eval(); top->clock = 1; top->eval(); }
    top->reset = 0;

    std::string uart;
    uint64_t start_cycle = 0, stop_cycle = 0, cycle = 0;
    bool start_set = false, stop_set = false, done = false;
    uint64_t n_ireq = 0, n_ifire = 0, n_dr = 0, n_dw = 0;  // --stats (stderr)
    uint64_t idle = 0;            // cycles since the last accepted bus access
    const char* end = "none";
    bool stats = false;
    for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--stats")) stats = true;
    for (cycle = 0; cycle < maxcycles; cycle++) {
        top->clock = 0;
        top->io_imemReady = istall ? accepts() : 1;
        top->io_dmemReady = dstall ? accepts() : 1;
        top->eval();
        uint32_t ia = top->io_imemAddr;
        bool ifire = top->io_imemReq && top->io_imemReady;
        // Pre-entry prefetch is not checked; after BENCH_STOP, a fetch outside
        // memory is the ebreak trap's vector (see the completion rule below).
        if (top->io_imemReq && !in_mem(ia) && !trampoline && !stop_set) oob = true;
        top->io_imemData = (trampoline && ia == reset_pc) ? 0x00000067u : rw(ia);
        top->io_imemData1 = rw(ia + 4);
        uint32_t da = top->io_dmemAddr;
        if (in_mem(da)) top->io_dmemRData = rw(da);
        else { top->io_dmemRData = 0; if (top->io_dmemREn && top->io_dmemReady) oob = true; }
        top->eval();
        if (top->io_dmemWEn && top->io_dmemReady) {
            if (da == BENCH_START_ADDR) { if (!start_set) { start_cycle = cycle; start_set = true; } }
            else if (da == BENCH_STOP_ADDR) { stop_cycle = cycle; stop_set = true; }
            else if (in_uart(da)) {
                for (int i = 0; i < 4; i++)
                    if ((top->io_dmemWEn >> i) & 1) { char c = (top->io_dmemWData >> (i * 8)) & 0xFF; if (c) uart.push_back(c); }
            } else if (in_mem(da)) ww(da, top->io_dmemWData, top->io_dmemWEn);
            else oob = true;
        }
        if (start_set && !stop_set) {
            n_ireq += top->io_imemReq; n_ifire += ifire;
            n_dr += top->io_dmemREn && top->io_dmemReady; n_dw += top->io_dmemWEn && top->io_dmemReady;
        }
        bool dfire = (top->io_dmemREn || top->io_dmemWEn) && top->io_dmemReady;
        idle = (ifire || dfire) ? 0 : idle + 1;
        // A core whose ebreak enters debug halt (VexRiscv with its debug
        // module) stops all bus traffic.
        if (stop_set && idle >= 200000) { done = true; end = "idle"; }
        if (ifire) {
            if (ia == entry) trampoline = false;
            // 64-bit fetch cores present the 8-byte-aligned address of the pair
            // A core with an instruction cache may run crt0's ebreak from the
            // cache; its trap then fetches the out-of-memory trap vector.
            if (stop_set && (ia == ebreak_pc || ia == (ebreak_pc & ~7u))) { done = true; end = "ebreak_fetch"; }
            else if (stop_set && !in_mem(ia)) { done = true; end = "trap_vector"; }
        }
        top->clock = 1; top->eval();
        if (done) break;
    }
    if (stats)
        fprintf(stderr, "bracket: imem req %llu fire %llu, dmem reads %llu writes %llu\n",
                (unsigned long long)n_ireq, (unsigned long long)n_ifire,
                (unsigned long long)n_dr, (unsigned long long)n_dw);
    std::string esc;
    for (char c : uart) {
        if (c == '\\' || c == '"') { esc.push_back('\\'); esc.push_back(c); }
        else if (c == '\n') esc += "\\n";
        else if (c == '\r') esc += "\\r";
        else if (c == '\t') esc += "\\t";
        else if (c >= 0x20 && c < 0x7F) esc.push_back(c);
    }
    printf("{\"ebreak\":%s,\"end\":\"%s\",\"maxcycles_hit\":%s,\"oob\":%s,\"cycles\":%llu,"
           "\"bench_start_cycle\":%llu,\"bench_stop_cycle\":%llu,\"bench_bracketed\":%s,\"uart\":\"%s\"}\n",
           done ? "true" : "false", end, done ? "false" : "true", oob ? "true" : "false",
           (unsigned long long)cycle, (unsigned long long)start_cycle, (unsigned long long)stop_cycle,
           (start_set && stop_set) ? "true" : "false", esc.c_str());
    delete top;
    return !done ? 2 : (oob ? 3 : 0);
}
