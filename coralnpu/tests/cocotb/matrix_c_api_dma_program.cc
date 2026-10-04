#include "include/coral_matrix.h"
#include <stdint.h>

int main(void) {
  const uintptr_t src = 0x80000000U;
  const uintptr_t dst = 0x80001000U;

  coral_msettilemi(3);
  coral_msettileni(5);
  coral_mlce32(CORAL_C0, (const void *)src, 64);
  coral_msce32(CORAL_C0, (void *)dst, 64);
  return 0;
}
