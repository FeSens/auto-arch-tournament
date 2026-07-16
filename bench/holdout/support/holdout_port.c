/* MMIO port layer for the held-out benchmark harness. No printf, no libc
   I/O: everything here is a direct byte write to UART_TX (0x10000000),
   matching the CoreMark baremetal portme.c convention used by
   bench/programs so the cosim UART capture (test/cosim/main.cpp) parses
   both benchmark families the same way. */

#include "holdout_port.h"

void
ho_putc(char c)
{
  UART_TX = (uint32_t)(unsigned char)c;
}

void
ho_puts(const char *s)
{
  while (*s)
    ho_putc(*s++);
}

void
ho_putu(unsigned v)
{
  char buf[10];
  int i = 0;

  if (v == 0) {
    ho_putc('0');
    return;
  }
  while (v > 0) {
    buf[i++] = (char)('0' + (v % 10));
    v /= 10;
  }
  while (i > 0)
    ho_putc(buf[--i]);
}
