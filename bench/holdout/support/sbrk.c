#include <stddef.h>

/* Bare-metal `_sbrk` for malloc (used by Dhrystone's Ptr_Glob/Next_Ptr_Glob
   setup in dhry_1.c's Dhry_init()). bench/programs/link.ld (read-only,
   don't-touch) does not define an `end` symbol, which the toolchain's
   default libnosys _sbrk needs to find the top of .bss; rather than touch
   the shared linker script, provide our own bump allocator over a small
   static arena, well within link.ld's 64K RAM region. */

#define HOLDOUT_HEAP_SIZE 4096

static char holdout_heap[HOLDOUT_HEAP_SIZE];
static char *holdout_heap_ptr = holdout_heap;

void *
_sbrk(ptrdiff_t incr)
{
  char *prev = holdout_heap_ptr;

  if (prev + incr > holdout_heap + HOLDOUT_HEAP_SIZE)
    return (void *)-1;

  holdout_heap_ptr += incr;
  return prev;
}
