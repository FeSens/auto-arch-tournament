#pragma once
#include <stdint.h>
#include <stddef.h>

#define ITERATIONS    100
/* Canonical CoreMark reporting config: 6K total → 2000 bytes per algorithm.
 * The coremark.h default is 2000 total (2K run, 666 bytes/algo) which
 * produces inflated iter/sec because working sets fit in registers. */
#define TOTAL_DATA_SIZE 6000
#define CLOCKS_PER_SEC 1
typedef uint32_t CORE_TICKS;
typedef uint32_t ee_u32;
typedef uint8_t  ee_u8;
typedef uint16_t ee_u16;
typedef int16_t  ee_s16;
typedef int32_t  ee_s32;
typedef int32_t  ee_ptr_int;
typedef size_t   ee_size_t;

#define MAIN_RETURN_TYPE int
#define MULTITHREAD  1
#define USE_FLOAT    0
#define MEM_METHOD   MEM_STACK
#define MEM_LOCATION "STACK"
#define HAS_FLOAT    0
#define HAS_TIME_H   0
#define HAS_STDIO    0
#define HAS_PRINTF   0
#define SEED_METHOD  SEED_VOLATILE
#define COMPILER_VERSION "riscv32-elf-gcc"
#define COMPILER_FLAGS   "-O2 -march=rv32im"

typedef struct { int dummy; } core_portable;

#define align_mem(x) (void *)(((ee_u32)(x) + 7) & ~7)
#define default_num_contexts MULTITHREAD

int  ee_printf(const char *fmt, ...);
void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

extern void       start_time(void);
extern void       stop_time(void);
extern CORE_TICKS get_time(void);
extern CORE_TICKS baremetal_timer_read(void);
extern ee_u32     time_in_secs(CORE_TICKS ticks);
#define GETMYTIME(_t)           (*(_t) = baremetal_timer_read())
#define MYTIMEDIFF(fin, ini)    ((fin) - (ini))
#define TIMER_RES_DIVIDER       1
#define SAMPLE_TIME_IMPLEMENTATION 1
#define EE_TICKS_PER_SEC        CLOCKS_PER_SEC
