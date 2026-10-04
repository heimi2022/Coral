#include "include/coral_matrix.h"
#include <stdint.h>

volatile uint32_t output_buffer[21] __attribute__((section(".data")));

static inline void gap(void) {
    asm volatile("nop; nop; nop" ::: "memory");
}

static inline uint32_t read_xtilem(void) {
    uint32_t out;
    asm volatile("csrr %0, 0x803" : "=r"(out));
    return out;
}

static inline uint32_t read_xtilen(void) {
    uint32_t out;
    asm volatile("csrr %0, 0x804" : "=r"(out));
    return out;
}

static inline uint32_t read_xtilek(void) {
    uint32_t out;
    asm volatile("csrr %0, 0x805" : "=r"(out));
    return out;
}

static inline void snapshot(volatile uint32_t *out, int base) {
    out[base + 0] = read_xtilem();
    out[base + 1] = read_xtilek();
    out[base + 2] = read_xtilen();
}

int main(int argc, char **argv) {
    gap();
    snapshot(output_buffer, 0);

    coral_msettilemi(4);
    gap();
    snapshot(output_buffer, 3);

    coral_msettilem(7);
    gap();
    snapshot(output_buffer, 6);

    coral_msettileki(8);
    gap();
    snapshot(output_buffer, 9);

    coral_msettilek(9);
    gap();
    snapshot(output_buffer, 12);

    coral_msettileni(16);
    gap();
    snapshot(output_buffer, 15);

    coral_msettilen(11);
    gap();
    snapshot(output_buffer, 18);

    return 0;
}
