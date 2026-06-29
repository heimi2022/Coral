// Copyright 2026 Google LLC
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
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>

#ifdef __INTELLISENSE__
#include "rvv_intellisense_shim.h"
#endif

namespace {

constexpr size_t kElementCount = 16;
constexpr int kInputFracBits = 12;
constexpr int kSigmoidFracBits = 15;
constexpr int kSigmoidBucketShift = 11;  // Q4.12 -> 0.5 step LUT bucket.
constexpr int kSigmoidLutSize = 32;

// Input uses Q4.12 fixed-point. Example: 4096 -> 1.0000, -2048 -> -0.5000.
const int16_t kInputQ4_12[kElementCount] = {
    -20480, -16384, -12288, -8192, -4096, -2048, -1024, 0,
    1024,   2048,   4096,   6144,  8192,  12288, 16384, 20480,
};

// 32-entry sigmoid LUT over 0.5-step buckets in [-8.0, 8.0), quantized to
// Q0.15. This keeps the demo fully integer while giving noticeably better
// accuracy than the earlier 16-entry int8 version.
const int16_t kSigmoidQ0_15Lut[kSigmoidLutSize] = {
    11,    18,    30,    49,    81,    133,   219,   360,
    589,   961,   1554,  2486,  3906,  5978,  8813,  12371,
    16384, 20397, 23955, 26790, 28862, 30282, 31214, 31807,
    32179, 32408, 32549, 32635, 32687, 32719, 32738, 32750,
};

int16_t output_rvv[kElementCount];
int16_t output_ref[kElementCount];

void print_str(const char* str) {
  const char* ptr = str;
  while (*ptr != '\0') {
    ++ptr;
  }
  write(1, str, ptr - str);
}

void print_char(char ch) { write(1, &ch, 1); }

void print_u32(uint32_t value) {
  char buf[10];
  int pos = 0;
  if (value == 0) {
    print_char('0');
    return;
  }
  while (value > 0) {
    buf[pos++] = static_cast<char>('0' + (value % 10));
    value /= 10;
  }
  while (pos > 0) {
    print_char(buf[--pos]);
  }
}

void print_i32(int32_t value) {
  if (value < 0) {
    print_char('-');
    value = -value;
  }
  print_u32(static_cast<uint32_t>(value));
}

void print_zero_padded_u32(uint32_t value, int digits) {
  char buf[10];
  int pos = digits;
  while (pos > 0) {
    buf[pos - 1] = static_cast<char>('0' + (value % 10));
    value /= 10;
    --pos;
  }
  write(1, buf, digits);
}

void print_q4_12(int16_t raw_value) {
  int32_t value = raw_value;
  if (value < 0) {
    print_char('-');
    value = -value;
  }
  print_u32(static_cast<uint32_t>(value >> kInputFracBits));
  print_char('.');
  const uint32_t frac =
      static_cast<uint32_t>((((value & 0xFFF) * 10000) + 2048) >> 12);
  print_zero_padded_u32(frac, 4);
}

int16_t lookup_sigmoid_q0_15(int16_t input_q4_12) {
  int bucket = input_q4_12 >> kSigmoidBucketShift;
  if (bucket < -16) {
    bucket = -16;
  } else if (bucket > 15) {
    bucket = 15;
  }
  return kSigmoidQ0_15Lut[bucket + 16];
}

int16_t silu_scalar_q4_12(int16_t input_q4_12) {
  const int16_t sigmoid_q0_15 = lookup_sigmoid_q0_15(input_q4_12);
  const int32_t product_q4_27 =
      static_cast<int32_t>(input_q4_12) * sigmoid_q0_15;
  return static_cast<int16_t>(product_q4_27 >> kSigmoidFracBits);
}

void silu_scalar_ref(const int16_t* input, int16_t* output, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    output[i] = silu_scalar_q4_12(input[i]);
  }
}

bool silu_rvv_q4_12(const int16_t* input, int16_t* output, size_t count) {
  const size_t lut_vlmax = __riscv_vsetvlmax_e16m4();
  if (lut_vlmax < kSigmoidLutSize) {
    return false;
  }

  // The 32-entry LUT fits in one i16m4 register group, so lookup stays on the
  // RVV datapath without extra scalar staging.
  const vint16m4_t lut_v =
      __riscv_vle16_v_i16m4(kSigmoidQ0_15Lut, kSigmoidLutSize);

  size_t idx = 0;
  while (idx < count) {
    const size_t vl = __riscv_vsetvl_e16m4(count - idx);
    const vint16m4_t in_v = __riscv_vle16_v_i16m4(input + idx, vl);

    vint16m4_t bucket_v = __riscv_vsra_vx_i16m4(in_v, kSigmoidBucketShift, vl);
    bucket_v = __riscv_vmax_vx_i16m4(bucket_v, -16, vl);
    bucket_v = __riscv_vmin_vx_i16m4(bucket_v, 15, vl);

    const vint16m4_t lut_idx_i16_v = __riscv_vadd_vx_i16m4(bucket_v, 16, vl);
    const vuint16m4_t lut_idx_v =
        __riscv_vreinterpret_v_i16m4_u16m4(lut_idx_i16_v);
    const vint16m4_t sigmoid_v =
        __riscv_vrgather_vv_i16m4(lut_v, lut_idx_v, vl);

    const vint32m8_t product_v = __riscv_vwmul_vv_i32m8(in_v, sigmoid_v, vl);
    const vint16m4_t out_v =
        __riscv_vnsra_wx_i16m4(product_v, kSigmoidFracBits, vl);
    __riscv_vse16_v_i16m4(output + idx, out_v, vl);

    idx += vl;
  }

  return true;
}

void print_row(size_t idx, int16_t input_value, int16_t output_value) {
  print_str("x[");
  print_u32(static_cast<uint32_t>(idx));
  print_str("] = ");
  print_q4_12(input_value);
  print_str(" -> ");
  print_q4_12(output_value);
  print_str(" (raw ");
  print_i32(output_value);
  print_str(")\n");
}

}  // namespace

int main() {
  silu_scalar_ref(kInputQ4_12, output_ref, kElementCount);
  const bool rvv_ok = silu_rvv_q4_12(kInputQ4_12, output_rvv, kElementCount);

  print_str("RVV SiLU demo (int16 Q4.12, LUT-based sigmoid)\n");
  if (!rvv_ok) {
    print_str("FAIL: VLEN too small for 32-entry LUT\n");
    return 1;
  }

  for (size_t i = 0; i < kElementCount; ++i) {
    print_row(i, kInputQ4_12[i], output_rvv[i]);
    if (output_rvv[i] != output_ref[i]) {
      print_str("Mismatch at index ");
      print_u32(static_cast<uint32_t>(i));
      print_str(": rvv=");
      print_i32(output_rvv[i]);
      print_str(", ref=");
      print_i32(output_ref[i]);
      print_char('\n');
      print_str("FAIL\n");
      return 1;
    }
  }

  print_str("PASS\n");
  return 0;
}
