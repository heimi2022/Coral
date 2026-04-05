#include <stdint.h>

volatile uint32_t output_buffer[21] __attribute__((section(".data")));

static inline void gap(void)
{
    asm volatile("nop; nop; nop" ::: "memory");
}

static inline void msettilemi_4(void)
{
    asm volatile(".word 0x2002002b" ::: "memory");
}

static inline void msettileki_8(void)
{
    asm volatile(".word 0x1004002b" ::: "memory");
}

static inline void msettileni_16(void)
{
    asm volatile(".word 0x3008002b" ::: "memory");
}

static inline void msettilem_reg(uint32_t value)
{
    asm volatile(
        "mv a0, %0\n\t"
        ".word 0x2205002b"
        :
        : "r"(value)
        : "a0", "memory");
}

static inline void msettilek_reg(uint32_t value)
{
    asm volatile(
        "mv a0, %0\n\t"
        ".word 0x1205002b"
        :
        : "r"(value)
        : "a0", "memory");
}

static inline void msettilen_reg(uint32_t value)
{
    asm volatile(
        "mv a0, %0\n\t"
        ".word 0x3205002b"
        :
        : "r"(value)
        : "a0", "memory");
}

static inline uint32_t read_xtilem(void)
{
    uint32_t out;
    asm volatile("csrr %0, 0x803" : "=r"(out));
    return out;
}

static inline uint32_t read_xtilen(void)
{
    uint32_t out;
    asm volatile("csrr %0, 0x804" : "=r"(out));
    return out;
}

static inline uint32_t read_xtilek(void)
{
    uint32_t out;
    asm volatile("csrr %0, 0x805" : "=r"(out));
    return out;
}

static inline void snapshot(volatile uint32_t *out, int base)
{
    out[base + 0] = read_xtilem();
    out[base + 1] = read_xtilek();
    out[base + 2] = read_xtilen();
}

int main(int argc, char **argv)
{
    gap();
    snapshot(output_buffer, 0);

    msettilemi_4();
    gap();
    snapshot(output_buffer, 3);

    msettilem_reg(7);
    gap();
    snapshot(output_buffer, 6);

    msettileki_8();
    gap();
    snapshot(output_buffer, 9);

    msettilek_reg(9);
    gap();
    snapshot(output_buffer, 12);

    msettileni_16();
    gap();
    snapshot(output_buffer, 15);

    msettilen_reg(11);
    gap();
    snapshot(output_buffer, 18);

    return 0;
}
