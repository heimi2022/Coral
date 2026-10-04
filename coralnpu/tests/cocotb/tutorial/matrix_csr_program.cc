#include "include/coral_matrix.h"
#include <stdint.h>

volatile uint32_t output_buffer[34] __attribute__((section(".data")));

#define READ_CSR(num)                             \
  ({                                              \
    uint32_t value;                               \
    asm volatile("csrr %0, " #num : "=r"(value)); \
    value;                                        \
  })

#define WRITE_CSR(num, value) \
  asm volatile("csrw " #num ", %0" : : "r"(value) : "memory")

static inline void gap(void) {
  asm volatile("nop; nop; nop" ::: "memory");
}

static inline void snapshot_matrix_ctrl(volatile uint32_t *out, int base) {
  out[base + 0] = READ_CSR(0x806);  // xmxrm
  out[base + 1] = READ_CSR(0x807);  // xmsat
  out[base + 2] = READ_CSR(0x808);  // xmfflags
  out[base + 3] = READ_CSR(0x809);  // xmfrm
  out[base + 4] = READ_CSR(0x80a);  // xmsaten
  out[base + 5] = READ_CSR(0x802);  // xmcsr
}

static inline void snapshot_tile_shape(volatile uint32_t *out, int base) {
  out[base + 0] = READ_CSR(0x803);  // xtilem
  out[base + 1] = READ_CSR(0x805);  // xtilek
  out[base + 2] = READ_CSR(0x804);  // xtilen
}

int main(int argc, char **argv) {
  gap();

  output_buffer[0] = READ_CSR(0xcc0);  // xmisa
  output_buffer[1] = READ_CSR(0xcc1);  // xtlenb
  output_buffer[2] = READ_CSR(0xcc2);  // xtrlenb
  output_buffer[3] = READ_CSR(0xcc3);  // xalenb

  snapshot_matrix_ctrl(output_buffer, 4);

  WRITE_CSR(0x806, 3U);
  WRITE_CSR(0x807, 1U);
  WRITE_CSR(0x808, 18U);
  WRITE_CSR(0x809, 4U);
  WRITE_CSR(0x80a, 1U);
  gap();
  snapshot_matrix_ctrl(output_buffer, 10);

  WRITE_CSR(0x802, 0xfffffbd1U);
  gap();
  snapshot_matrix_ctrl(output_buffer, 16);

  snapshot_tile_shape(output_buffer, 22);

  coral_msettilemi(4);
  coral_msettileki(8);
  coral_msettileni(16);
  gap();
  snapshot_tile_shape(output_buffer, 25);

  WRITE_CSR(0x803, 99U);
  WRITE_CSR(0x805, 77U);
  WRITE_CSR(0x804, 55U);
  gap();
  snapshot_tile_shape(output_buffer, 28);

  coral_msettilem(7U);
  coral_msettilek(9U);
  coral_msettilen(11U);
  gap();
  snapshot_tile_shape(output_buffer, 31);

  return 0;
}
