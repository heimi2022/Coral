// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <riscv_vector.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#ifdef __INTELLISENSE__
#include "rvv_intellisense_shim.h"
#endif

int8_t input_1[1024];
int8_t input_2[1024];
int16_t output[1024];

static void print_str(const char* s) {
  write(1, s, strlen(s));
}

static void print_digit(int value) {
  char ch = '0' + value;
  write(1, &ch, 1);
}

int main() {
  memset(input_1, 1, sizeof(input_1));
  memset(input_2, 6, sizeof(input_2));

  for (int idx = 0; (idx + 31) < 1024; idx += 32) {
    vint8m4_t input_v2 = __riscv_vle8_v_i8m4(&input_2[idx], 32);
    vint8m4_t input_v1 = __riscv_vle8_v_i8m4(&input_1[idx], 32);
    vint16m8_t temp_sum = __riscv_vwadd_vv_i16m8(input_v1, input_v2, 32);
    __riscv_vse16_v_i16m8(&output[idx], temp_sum, 32);
  }

  print_str("RVV add intrinsic demo\n");
  print_str("input_1[0] = ");
  print_digit(input_1[0]);
  print_str(", input_2[0] = ");
  print_digit(input_2[0]);
  print_str("\n");
  print_str("output[0..7] =");
  for (int i = 0; i < 8; ++i) {
    print_str(" ");
    print_digit(output[i]);
  }
  print_str("\n");

  for (int i = 0; i < 1024; ++i) {
    if (output[i] != 7) {
      print_str("FAIL\n");
      return 1;
    }
  }

  print_str("PASS\n");
  return 0;
}
