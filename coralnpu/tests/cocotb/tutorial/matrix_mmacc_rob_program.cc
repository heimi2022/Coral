#include "include/coral_matrix.h"
#include <stdint.h>

volatile uint32_t output_buffer[4] __attribute__((section(".data")));

static inline void gap(void) {
  asm volatile("nop; nop; nop" ::: "memory");
}

static inline uint32_t read_xtilem(void) {
  uint32_t out;
  asm volatile("csrr %0, 0x803" : "=r"(out));
  return out;
}

static inline uint32_t read_xtilek(void) {
  uint32_t out;
  asm volatile("csrr %0, 0x805" : "=r"(out));
  return out;
}

static inline uint32_t read_xtilen(void) {
  uint32_t out;
  asm volatile("csrr %0, 0x804" : "=r"(out));
  return out;
}

int main(int argc, char **argv) {
  coral_msettilemi(1);
  coral_msettileki(1);
  coral_msettileni(1);
  gap();

  output_buffer[0] = read_xtilem();
  output_buffer[1] = read_xtilek();
  output_buffer[2] = read_xtilen();

  coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);
  coral_msettilem(9U);
  gap();

  output_buffer[3] = read_xtilem();
  return 0;
}
