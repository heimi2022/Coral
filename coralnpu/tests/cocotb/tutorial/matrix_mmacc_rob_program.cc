#include <stdint.h>

volatile uint32_t output_buffer[4] __attribute__((section(".data")));

static inline void gap(void) {
  asm volatile("nop; nop; nop" ::: "memory");
}

static inline void msettilemi_1(void) {
  asm volatile(".word 0x2000802b" ::: "memory");
}

static inline void msettileki_1(void) {
  asm volatile(".word 0x1000802b" ::: "memory");
}

static inline void msettileni_1(void) {
  asm volatile(".word 0x3000802b" ::: "memory");
}

static inline void msettilem_reg(uint32_t value) {
  asm volatile(
      "mv a0, %0\n\t"
      ".word 0x2205002b"
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
  msettilemi_1();
  msettileki_1();
  msettileni_1();
  gap();

  output_buffer[0] = read_xtilem();
  output_buffer[1] = read_xtilek();
  output_buffer[2] = read_xtilen();

  mmacc_w_b_tr0_tr1_acc0();
  msettilem_reg(9U);
  gap();

  output_buffer[3] = read_xtilem();
  return 0;
}
