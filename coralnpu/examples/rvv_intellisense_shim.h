#ifndef RVV_INTELLISENSE_SHIM_H_
#define RVV_INTELLISENSE_SHIM_H_

#ifdef __INTELLISENSE__

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * VS Code cpptools can find riscv_vector.h after includePath is configured,
 * but it still does not materialize RVV builtin types/functions the same way
 * the real compiler does. Keep a tiny IntelliSense-only shim so example code
 * stays readable in the editor without affecting real builds.
 */
typedef struct {
  long long lane[4];
} vint8m4_t;

typedef struct {
  long long lane[8];
} vint16m8_t;

vint8m4_t __riscv_vle8_v_i8m4(const int8_t* base, size_t vl);
vint16m8_t __riscv_vwadd_vv_i16m8(vint8m4_t vs2, vint8m4_t vs1, size_t vl);
void __riscv_vse16_v_i16m8(int16_t* base, vint16m8_t value, size_t vl);

#ifdef __cplusplus
}
#endif

#endif  // __INTELLISENSE__

#endif  // RVV_INTELLISENSE_SHIM_H_
