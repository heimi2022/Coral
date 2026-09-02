#include "fpga/sw/uart.h"

int main() {
  uart_init(CLOCK_FREQUENCY_MHZ);
  uart_puts("hello\r\n");

  while (true) {
    asm volatile("wfi");
  }
}
