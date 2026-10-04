#include "include/coral_matrix.h"
#include <stdint.h>

int main(void) {
  const uintptr_t a = 0x80000000U;
  const uintptr_t b = 0x80001000U;
  const uintptr_t a_scale = 0x80002000U;
  const uintptr_t b_scale = 0x80003000U;
  const uintptr_t c = 0x80004000U;
  const uintptr_t dst = 0x80005000U;

  coral_msettilemi(1);
  coral_msettileki(32);
  coral_msettileni(1);

  coral_mlae8(CORAL_A0, (const void *)a, 64);
  coral_mlbe8(CORAL_B1, (const void *)b, 64);
  coral_mlate8(CORAL_A0, (const void *)a_scale, 64);
  coral_mlbte8(CORAL_B1, (const void *)b_scale, 64);
  coral_mlce32(CORAL_C0, (const void *)c, 64);
  coral_mmacc_w_b(CORAL_C0, CORAL_B1, CORAL_A0);
  coral_msce32(CORAL_C0, (void *)dst, 64);
  return 0;
}
