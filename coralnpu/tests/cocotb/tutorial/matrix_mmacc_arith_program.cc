#include <stdint.h>

volatile uint32_t output_buffer[4] __attribute__((section(".data")));
volatile uint32_t start_flag __attribute__((section(".data")));

static inline void gap(void) {
  asm volatile("nop; nop; nop" ::: "memory");
}

static inline void msettilem_reg(uint32_t value) {
  asm volatile(
      "mv a0, %0\n\t"
      ".word 0x2205002b"
      :
      : "r"(value)
      : "a0", "memory");
}

static inline void msettilek_reg(uint32_t value) {
  asm volatile(
      "mv a0, %0\n\t"
      ".word 0x1205002b"
      :
      : "r"(value)
      : "a0", "memory");
}

static inline void msettilen_reg(uint32_t value) {
  asm volatile(
      "mv a0, %0\n\t"
      ".word 0x3205002b"
      :
      : "r"(value)
      : "a0", "memory");
}

static inline void mmacc_w_b_tr0_tr1_acc0(void) {
  asm volatile(".word 0x19900a2b" ::: "memory");
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
  start_flag = 0;

  msettilem_reg(2U);
  msettilek_reg(4U);
  msettilen_reg(3U);
  gap();

  output_buffer[0] = read_xtilem();
  output_buffer[1] = read_xtilek();
  output_buffer[2] = read_xtilen();

  while (start_flag == 0U) {
    asm volatile("nop" ::: "memory");
  }

  mmacc_w_b_tr0_tr1_acc0();
  gap();

  output_buffer[3] = 0xACCE5501U;
  return 0;
}
