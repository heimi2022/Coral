// Copyright 2026 Google LLC
// Licensed under the Apache License, Version 2.0.

#include <stdint.h>

#include <riscv_vector.h>

#include "fpga/sw/uart.h"

#define REG32(addr) (*(volatile uint32_t*)(addr))

#define DMA_BASE      0x40050000u
#define DMA_CTRL      (DMA_BASE + 0x00u)
#define DMA_STATUS    (DMA_BASE + 0x04u)
#define DMA_DESC_ADDR (DMA_BASE + 0x08u)
#define DDR_BASE      0x80000000u

struct __attribute__((packed, aligned(32))) dma_descriptor {
  uint32_t src_addr;
  uint32_t dst_addr;
  uint32_t len_flags;
  uint32_t next_desc;
  uint32_t poll_addr;
  uint32_t poll_mask;
  uint32_t poll_value;
  uint32_t reserved;
};

static inline uint32_t make_len_flags(uint32_t len, uint32_t width_log2) {
  return (len & 0x00ffffffu) | ((width_log2 & 0x7u) << 24);
}

// The linker places these objects in DTCM. They do not overlap.
static volatile struct dma_descriptor descriptor __attribute__((aligned(32)));
static volatile uint32_t dtcm_buffer[16] __attribute__((aligned(64)));
static volatile uint8_t regression_buffer[4224] __attribute__((aligned(64)));

// The three buffers are separate DTCM regions in the software data image.
static volatile uint32_t dtcm1_vector[10] __attribute__((aligned(64)));
static volatile uint32_t dtcm2_vector[10] __attribute__((aligned(64)));
static volatile uint32_t dtcm3_result[5] __attribute__((aligned(64)));

static volatile uint32_t* const ddr_source =
    (volatile uint32_t*)(DDR_BASE + 0x0000u);
static volatile uint32_t* const ddr_destination =
    (volatile uint32_t*)(DDR_BASE + 0x0100u);

static int dma_wait_done(void) {
  for (uint32_t cycle = 0; cycle < 10000000u; ++cycle) {
    const uint32_t status = REG32(DMA_STATUS);
    if (status & 0x2u) return (status & 0x4u) ? -1 : 0;
    if (status & 0x4u) return -1;
  }
  return -2;
}

static int run_dma(uint32_t src, uint32_t dst, uint32_t bytes,
                   uint32_t width_log2 = 2) {
  descriptor.src_addr = src;
  descriptor.dst_addr = dst;
  descriptor.len_flags = make_len_flags(bytes, width_log2);
  descriptor.next_desc = 0;
  descriptor.poll_addr = 0;
  descriptor.poll_mask = 0;
  descriptor.poll_value = 0;
  descriptor.reserved = 0;

  asm volatile("fence iorw, iorw" ::: "memory");

  // DMA reads the descriptor through the Coral device/TCM path.
  REG32(DMA_DESC_ADDR) = (uint32_t)(uintptr_t)&descriptor;
  REG32(DMA_CTRL) = 0x3u;  // enable + start
  asm volatile("fence iorw, iorw" ::: "memory");
  // START clears when the engine accepts the command and clears old DONE.
  for (uint32_t poll = 0; poll < 10000000u; ++poll) {
    if ((REG32(DMA_CTRL) & 0x2u) == 0) {
      const int result = dma_wait_done();
      asm volatile("fence iorw, iorw" ::: "memory");
      return result;
    }
  }
  return -2;
}

struct transfer_case {
  uint32_t bytes;
  uint32_t width_log2;
  uint32_t ddr_offset;
  uint32_t dtcm_offset;
};

static uint8_t pattern(uint32_t index, uint32_t seed) {
  return (uint8_t)((index * 37u) ^ (index >> 8) ^ seed);
}

static void regression_fail(uint32_t test, uint32_t direction,
                            uint32_t index, uint32_t expected, uint32_t actual) {
  uart_puts("FAIL case/dir/index/expected/actual:");
  const uint32_t values[] = {test, direction, index, expected, actual};
  for (uint32_t i = 0; i < 5; ++i) {
    uart_puts(" ");
    uart_puthex32(values[i]);
  }
  uart_puts("\r\n");
  while (true) asm volatile("wfi");
}

static void run_regression() {
  // Addresses are aligned to the transfer width; lengths are its multiples.
  const transfer_case cases[] = {
      {1, 0, 1, 3}, {31, 0, 15, 5}, {34, 1, 30, 2},
      {68, 2, 12, 4}, {128, 3, 24, 8}, {256, 4, 16, 32},
      {64, 2, 0xff0, 12}, {4096, 4, 0, 16},
  };
  for (uint32_t test = 0; test < sizeof(cases) / sizeof(cases[0]); ++test) {
    const transfer_case& c = cases[test];
    for (uint32_t direction = 0; direction < 2; ++direction) {
      volatile uint8_t* ddr = (volatile uint8_t*)(uintptr_t)
          (DDR_BASE + 0x10000u + c.ddr_offset);
      volatile uint8_t* dtcm = regression_buffer + 32 + c.dtcm_offset;
      volatile uint8_t* src = direction == 0 ? ddr : dtcm;
      volatile uint8_t* dst = direction == 0 ? dtcm : ddr;
      const uint32_t seed = 0x53u + test * 11u + direction * 71u;
      for (int32_t i = -16; i < (int32_t)c.bytes + 16; ++i)
        dst[i] = 0xa5;
      for (uint32_t i = 0; i < c.bytes; ++i)
        src[i] = pattern(i, seed);
      const int result = run_dma((uint32_t)(uintptr_t)src,
                                 (uint32_t)(uintptr_t)dst,
                                 c.bytes, c.width_log2);
      if (result != 0)
        regression_fail(test, direction, 0xffffffffu, 0, (uint32_t)result);
      for (int32_t i = -16; i < (int32_t)c.bytes + 16; ++i) {
        const uint8_t expected = (i < 0 || i >= (int32_t)c.bytes)
            ? 0xa5 : pattern((uint32_t)i, seed);
        const uint8_t actual = dst[i];
        if (actual != expected)
          regression_fail(test, direction, (uint32_t)i, expected, actual);
      }
      // Print only the first few bytes, after checking payload and guards.
      uart_puts(direction == 0 ? "PASS R" : "PASS W");
      uart_puthex8((uint8_t)test);
      uart_puts(":");
      for (uint32_t i = 0; i < c.bytes && i < 4; ++i) {
        uart_puts(" ");
        uart_puthex8(dst[i]);
      }
      uart_puts("\r\n");
    }
  }
  uart_puts("PASS DMA regression\r\n");
}

static void run_rvv_dma_pipeline() {
  static volatile uint32_t* const ddr1 =
      (volatile uint32_t*)(DDR_BASE + 0x2000u);
  static volatile uint32_t* const ddr2 =
      (volatile uint32_t*)(DDR_BASE + 0x2100u);

  // DTCM1 holds two 5-element operands: [A0..A4, B0..B4].
  for (uint32_t i = 0; i < 5; ++i) {
    dtcm1_vector[i] = 10u + i;
    dtcm1_vector[5 + i] = 100u + i;
    dtcm2_vector[i] = 0;
    dtcm2_vector[5 + i] = 0;
    dtcm3_result[i] = 0;
  }
  for (uint32_t i = 0; i < 10; ++i)
    ddr1[i] = 0;
  for (uint32_t i = 0; i < 5; ++i)
    ddr2[i] = 0;

  // DTCM1 -> DDR1 -> DTCM2.
  uart_puts("RVV pipeline start\r\n");
  uart_puts("RVV DMA1 DTCM1->DDR1 start\r\n");
  if (run_dma((uint32_t)(uintptr_t)dtcm1_vector,
              (uint32_t)(uintptr_t)ddr1, 10 * sizeof(uint32_t)) != 0) {
    uart_puts("FAIL RVV DMA1 DTCM1->DDR1\r\n");
    while (true) asm volatile("wfi");
  }
  uart_puts("RVV DMA1 DTCM1->DDR1 done\r\n");
  uart_puts("RVV DMA1 DDR1->DTCM2 start\r\n");
  if (run_dma((uint32_t)(uintptr_t)ddr1,
              (uint32_t)(uintptr_t)dtcm2_vector, 10 * sizeof(uint32_t)) != 0) {
    uart_puts("FAIL RVV DMA1 DDR1->DTCM2\r\n");
    while (true) asm volatile("wfi");
  }
  uart_puts("RVV DMA1 DDR1->DTCM2 done\r\n");

  // VLEN=128 has only four 32-bit lanes at LMUL=1, so m2 is needed for vl=5.
  uart_puts("RVV add start\r\n");
  const size_t vl = 5;
  uart_puts("RVV load A start\r\n");
  const vuint32m2_t a = __riscv_vle32_v_u32m2(
      (const uint32_t*)dtcm2_vector, vl);
  uart_puts("RVV load A done\r\n");
  uart_puts("RVV load B start\r\n");
  const vuint32m2_t b = __riscv_vle32_v_u32m2(
      (const uint32_t*)(dtcm2_vector + 5), vl);
  uart_puts("RVV load B done\r\n");
  uart_puts("RVV vadd start\r\n");
  const vuint32m2_t sum = __riscv_vadd_vv_u32m2(a, b, vl);
  uart_puts("RVV vadd done\r\n");
  uart_puts("RVV store start\r\n");
  __riscv_vse32_v_u32m2((uint32_t*)dtcm2_vector, sum, vl);
  uart_puts("RVV store done\r\n");
  uart_puts("RVV add done\r\n");

  for (uint32_t i = 0; i < 5; ++i) {
    const uint32_t expected = (10u + i) + (100u + i);
    if (dtcm2_vector[i] != expected) {
      uart_puts("FAIL RVV result index ");
      uart_puthex32(i);
      uart_puts("\r\n");
      while (true) asm volatile("wfi");
    }
  }

  // DTCM2 -> DDR2 -> DTCM3.
  uart_puts("RVV DMA2 DTCM2->DDR2 start\r\n");
  if (run_dma((uint32_t)(uintptr_t)dtcm2_vector,
              (uint32_t)(uintptr_t)ddr2, 5 * sizeof(uint32_t)) != 0) {
    uart_puts("FAIL RVV DMA2 DTCM2->DDR2\r\n");
    while (true) asm volatile("wfi");
  }
  uart_puts("RVV DMA2 DTCM2->DDR2 done\r\n");
  uart_puts("RVV DMA2 DDR2->DTCM3 start\r\n");
  if (run_dma((uint32_t)(uintptr_t)ddr2,
              (uint32_t)(uintptr_t)dtcm3_result, 5 * sizeof(uint32_t)) != 0) {
    uart_puts("FAIL RVV DMA2 DDR2->DTCM3\r\n");
    while (true) asm volatile("wfi");
  }
  uart_puts("RVV DMA2 DDR2->DTCM3 done\r\n");

  uart_puts("RVV result DTCM3:");
  for (uint32_t i = 0; i < 5; ++i) {
    const uint32_t expected = (10u + i) + (100u + i);
    if (dtcm3_result[i] != expected) {
      uart_puts(" FAIL index ");
      uart_puthex32(i);
      uart_puts("\r\n");
      while (true) asm volatile("wfi");
    }
    uart_puts(" ");
    uart_puthex32(dtcm3_result[i]);
  }
  uart_puts("\r\nPASS RVV DMA pipeline\r\n");
}

static void run_rvv_only() {
  // 先绕过 DMA，直接验证 DTCM 中的 RVV load/add/store 指令。
  for (uint32_t i = 0; i < 5; ++i) {
    dtcm2_vector[i] = 10u + i;
    dtcm2_vector[5 + i] = 100u + i;
    dtcm3_result[i] = 0;
  }

  uart_puts("RVV-only start\r\n");
  const size_t vl = 5;
  uart_puts("RVV-only load A start\r\n");
  const vuint32m2_t a = __riscv_vle32_v_u32m2(
      (const uint32_t*)dtcm2_vector, vl);
  uart_puts("RVV-only load A done\r\n");
  const vuint32m2_t b = __riscv_vle32_v_u32m2(
      (const uint32_t*)(dtcm2_vector + 5), vl);
  uart_puts("RVV-only load B done\r\n");
  const vuint32m2_t sum = __riscv_vadd_vv_u32m2(a, b, vl);
  uart_puts("RVV-only vadd done\r\n");
  __riscv_vse32_v_u32m2((uint32_t*)dtcm3_result, sum, vl);
  uart_puts("RVV-only store done\r\n");

  uart_puts("RVV-only result:");
  for (uint32_t i = 0; i < 5; ++i) {
    if (dtcm3_result[i] != 110u + 2u * i) {
      uart_puts(" FAIL index ");
      uart_puthex32(i);
      uart_puts("\r\n");
      while (true) asm volatile("wfi");
    }
    uart_puts(" ");
    uart_puthex32(dtcm3_result[i]);
  }
  uart_puts("\r\nPASS RVV-only\r\n");
}

int main() {
  uart_init(CLOCK_FREQUENCY_MHZ);
  uart_puts("RVV DMA pipeline test start\r\n");

  // 基础 DMA 测试暂时跳过，当前只定位 RVV + DMA 流水。
#if 0
  const uint32_t words = 16;
  const uint32_t bytes = words * sizeof(uint32_t);

  // Initialize DDR through CPU stores before starting the DMA.
  for (uint32_t i = 0; i < words; ++i) {
    ddr_source[i] = 0xCAFE0000u + i;
    dtcm_buffer[i] = 0;
  }

  // Test 1: DDR -> DTCM.
  if (run_dma((uint32_t)(uintptr_t)ddr_source,
              (uint32_t)(uintptr_t)dtcm_buffer, bytes) != 0) {
    uart_puts("FAIL DDR->DTCM DMA\r\n");
    return 1;
  }
  for (uint32_t i = 0; i < words; ++i) {
    if (dtcm_buffer[i] != 0xCAFE0000u + i) {
      uart_puts("FAIL DTCM verify index ");
      uart_puthex32(i);
      uart_puts("\r\n");
      return 1;
    }
  }
  uart_puts("PASS DDR->DTCM\r\n");
  uart_puts("DTCM[0..3]:");
  for (uint32_t i = 0; i < 4; ++i) {
    uart_puts(" ");
    uart_puthex32(dtcm_buffer[i]);
  }
  uart_puts("\r\n");

  // Test 2: DTCM -> DDR.
  for (uint32_t i = 0; i < words; ++i) {
    dtcm_buffer[i] = 0xBEEF0000u + i;
    ddr_destination[i] = 0;
  }
  if (run_dma((uint32_t)(uintptr_t)dtcm_buffer,
              (uint32_t)(uintptr_t)ddr_destination, bytes) != 0) {
    uart_puts("FAIL DTCM->DDR DMA\r\n");
    return 1;
  }
  for (uint32_t i = 0; i < words; ++i) {
    if (ddr_destination[i] != 0xBEEF0000u + i) {
      uart_puts("FAIL DDR verify index ");
      uart_puthex32(i);
      uart_puts("\r\n");
      return 1;
    }
  }
  uart_puts("PASS DTCM->DDR\r\n");
  uart_puts("DDR[0..3]:");
  for (uint32_t i = 0; i < 4; ++i) {
    uart_puts(" ");
    uart_puthex32(ddr_destination[i]);
  }
  uart_puts("\r\n");
#endif
  // 暂时跳过扩展 DMA 回归，单独验证后面的 RVV + DMA 流水。
  // run_regression();
  // 恢复 DMA 搬运与 RVV 加法串联测试。
  // run_rvv_only();
  run_rvv_dma_pipeline();
  uart_puts("RVV-DMA TEST PASS\r\n");

  while (true) asm volatile("wfi");
}
