// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <stdint.h>

uint32_t input1_buffer[1] __attribute__((section(".data")));
uint32_t input2_buffer[1] __attribute__((section(".data")));
uint32_t output_buffer[1] __attribute__((section(".data")));

static inline uint32_t matadd(uint32_t a, uint32_t b)
{
    uint32_t out;
    asm volatile(
        ".insn r 0x0b, 0x0, 0x2a, %0, %1, %2\n"
        : "=r"(out)
        : "r"(a), "r"(b));
    return out;
}

int main(int argc, char **argv)
{
    output_buffer[0] = matadd(input1_buffer[0], input2_buffer[0]);
    return 0;
}
