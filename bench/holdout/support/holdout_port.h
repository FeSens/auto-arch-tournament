#ifndef HOLDOUT_PORT_H
#define HOLDOUT_PORT_H
#include <stdint.h>
#define UART_TX      (*(volatile uint32_t *)0x10000000u)
#define BENCH_START  (*(volatile uint32_t *)0x10000100u)
#define BENCH_STOP   (*(volatile uint32_t *)0x10000104u)
void ho_putc(char c);
void ho_puts(const char *s);
void ho_putu(unsigned v);
#endif
