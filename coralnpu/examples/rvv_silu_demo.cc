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

namespace
{

    constexpr size_t kElementCount = 32;
    constexpr int kFracBits = 10;
    constexpr int kNeg16Q = -(16 << kFracBits);
    constexpr int kNeg1Q = -(1 << kFracBits);
    constexpr int kPos2Q = 2 << kFracBits;
    constexpr int kPos8Q = 8 << kFracBits;

    // Input uses 32 Q6.10 values so the current Coral RVV configuration can fill
    // one full e16,m4 vector iteration while still covering the piecewise
    // boundaries and representative interior points.
    const int16_t kInputQ6_10[kElementCount] = {
        -20 << kFracBits,
        -18 << kFracBits,
        -16 << kFracBits,
        -15 << kFracBits,
        -14 << kFracBits,
        -12 << kFracBits,
        -10 << kFracBits,
        -8 << kFracBits,
        -6 << kFracBits,
        -4 << kFracBits,
        -3 << kFracBits,
        -2 << kFracBits,
        -(3 << (kFracBits - 1)),
        -1 << kFracBits,
        -(1 << (kFracBits - 1)),
        0,
        1 << (kFracBits - 1),
        1 << kFracBits,
        3 << (kFracBits - 1),
        2 << kFracBits,
        3 << kFracBits,
        4 << kFracBits,
        5 << kFracBits,
        6 << kFracBits,
        7 << kFracBits,
        8 << kFracBits,
        9 << kFracBits,
        10 << kFracBits,
        12 << kFracBits,
        14 << kFracBits,
        16 << kFracBits,
        20 << kFracBits,
    };

    // Piecewise quadratic SiLU approximation coefficients in Q6.10.
    constexpr int16_t kSeg0A2 = -3;
    constexpr int16_t kSeg0A1 = -62;
    constexpr int16_t kSeg0A0 = -315;

    constexpr int16_t kSeg1A2 = 201;
    constexpr int16_t kSeg1A1 = 514;
    constexpr int16_t kSeg1A0 = 16;

    constexpr int16_t kSeg2A2 = -10;
    constexpr int16_t kSeg2A1 = 1162;
    constexpr int16_t kSeg2A0 = -472;

    int16_t output_rvv[kElementCount];
    int16_t output_ref[kElementCount];

    void print_str(const char *str)
    {
        const char *ptr = str;
        while (*ptr != '\0')
        {
            ++ptr;
        }
        write(1, str, ptr - str);
    }

    void print_char(char ch) { write(1, &ch, 1); }

    void print_u32(uint32_t value)
    {
        char buf[10];
        int pos = 0;
        if (value == 0)
        {
            print_char('0');
            return;
        }
        while (value > 0)
        {
            buf[pos++] = static_cast<char>('0' + (value % 10));
            value /= 10;
        }
        while (pos > 0)
        {
            print_char(buf[--pos]);
        }
    }

    void print_i32(int32_t value)
    {
        if (value < 0)
        {
            print_char('-');
            value = -value;
        }
        print_u32(static_cast<uint32_t>(value));
    }

    void print_zero_padded_u32(uint32_t value, int digits)
    {
        char buf[10];
        int pos = digits;
        while (pos > 0)
        {
            buf[pos - 1] = static_cast<char>('0' + (value % 10));
            value /= 10;
            --pos;
        }
        write(1, buf, digits);
    }

    void print_q6_10(int16_t raw_value)
    {
        int32_t value = raw_value;
        if (value < 0)
        {
            print_char('-');
            value = -value;
        }
        print_u32(static_cast<uint32_t>(value >> kFracBits));
        print_char('.');
        const uint32_t frac =
            static_cast<uint32_t>((((value & ((1 << kFracBits) - 1)) * 10000) +
                                   (1 << (kFracBits - 1))) >>
                                  kFracBits);
        print_zero_padded_u32(frac, 4);
    }

    int16_t eval_poly_scalar(int16_t input_q6_10, int16_t a2_q, int16_t a1_q,
                             int16_t a0_q)
    {
        const int32_t t =
            ((static_cast<int32_t>(a2_q) * input_q6_10) >> kFracBits) + a1_q;
        const int32_t y =
            ((t * input_q6_10) >> kFracBits) + static_cast<int32_t>(a0_q);
        return static_cast<int16_t>(y);
    }

    int16_t silu_scalar_q6_10(int16_t input_q6_10)
    {
        if (input_q6_10 <= kNeg16Q)
        {
            return 0;
        }
        if (input_q6_10 > kPos8Q)
        {
            return input_q6_10;
        }
        if (input_q6_10 < kNeg1Q)
        {
            return eval_poly_scalar(input_q6_10, kSeg0A2, kSeg0A1, kSeg0A0);
        }
        if (input_q6_10 < kPos2Q)
        {
            return eval_poly_scalar(input_q6_10, kSeg1A2, kSeg1A1, kSeg1A0);
        }
        return eval_poly_scalar(input_q6_10, kSeg2A2, kSeg2A1, kSeg2A0);
    }

    void silu_scalar_ref(const int16_t *input, int16_t *output, size_t count)
    {
        for (size_t i = 0; i < count; ++i)
        {
            output[i] = silu_scalar_q6_10(input[i]);
        }
    }

    bool silu_rvv_q6_10(const int16_t *input, int16_t *output, size_t count)
    {
        size_t idx = 0;
        while (idx < count)
        {
            const size_t vl = __riscv_vsetvl_e16m4(count - idx);
            const vint16m4_t in_v = __riscv_vle16_v_i16m4(input + idx, vl);

            const vbool4_t mask_le_neg16 =
                __riscv_vmsle_vx_i16m4_b4(in_v, kNeg16Q, vl);
            const vbool4_t mask_lt_neg1 =
                __riscv_vmslt_vx_i16m4_b4(in_v, kNeg1Q, vl);
            const vbool4_t mask_lt_pos2 =
                __riscv_vmslt_vx_i16m4_b4(in_v, kPos2Q, vl);
            const vbool4_t mask_gt_pos8 =
                __riscv_vmsgt_vx_i16m4_b4(in_v, kPos8Q, vl);

            vint16m4_t a2_v = __riscv_vmv_v_x_i16m4(kSeg2A2, vl);
            vint16m4_t a1_v = __riscv_vmv_v_x_i16m4(kSeg2A1, vl);
            vint16m4_t a0_v = __riscv_vmv_v_x_i16m4(kSeg2A0, vl);

            a2_v = __riscv_vmerge_vxm_i16m4(a2_v, kSeg1A2, mask_lt_pos2, vl);
            a1_v = __riscv_vmerge_vxm_i16m4(a1_v, kSeg1A1, mask_lt_pos2, vl);
            a0_v = __riscv_vmerge_vxm_i16m4(a0_v, kSeg1A0, mask_lt_pos2, vl);

            a2_v = __riscv_vmerge_vxm_i16m4(a2_v, kSeg0A2, mask_lt_neg1, vl);
            a1_v = __riscv_vmerge_vxm_i16m4(a1_v, kSeg0A1, mask_lt_neg1, vl);
            a0_v = __riscv_vmerge_vxm_i16m4(a0_v, kSeg0A0, mask_lt_neg1, vl);

            vint32m8_t t_v = __riscv_vwmul_vv_i32m8(a2_v, in_v, vl);
            vint16m4_t t_q_v = __riscv_vnsra_wx_i16m4(t_v, kFracBits, vl);
            t_q_v = __riscv_vadd_vv_i16m4(t_q_v, a1_v, vl);

            vint32m8_t y_v = __riscv_vwmul_vv_i32m8(t_q_v, in_v, vl);
            vint16m4_t y_q_v = __riscv_vnsra_wx_i16m4(y_v, kFracBits, vl);
            y_q_v = __riscv_vadd_vv_i16m4(y_q_v, a0_v, vl);

            y_q_v = __riscv_vmerge_vxm_i16m4(y_q_v, 0, mask_le_neg16, vl);
            y_q_v = __riscv_vmerge_vvm_i16m4(y_q_v, in_v, mask_gt_pos8, vl);

            __riscv_vse16_v_i16m4(output + idx, y_q_v, vl);

            idx += vl;
        }

        return true;
    }

    void print_row(size_t idx, int16_t input_value, int16_t output_value)
    {
        print_str("x[");
        print_u32(static_cast<uint32_t>(idx));
        print_str("] = ");
        print_q6_10(input_value);
        print_str(" -> ");
        print_q6_10(output_value);
        print_str(" (raw ");
        print_i32(output_value);
        print_str(")\n");
    }

} // namespace

int main()
{
    silu_scalar_ref(kInputQ6_10, output_ref, kElementCount);
    const bool rvv_ok = silu_rvv_q6_10(kInputQ6_10, output_rvv, kElementCount);

    print_str("RVV SiLU demo (piecewise quadratic, int16 Q6.10)\n");
    if (!rvv_ok)
    {
        print_str("FAIL: RVV path setup error\n");
        return 1;
    }

    for (size_t i = 0; i < kElementCount; ++i)
    {
        print_row(i, kInputQ6_10[i], output_rvv[i]);
        if (output_rvv[i] != output_ref[i])
        {
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
