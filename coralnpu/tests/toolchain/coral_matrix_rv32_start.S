/* Minimal bare-metal entry point for the external RV32 Coral toolchain. */

.section .text.start, "ax", @progbits
.balign 4
.global _start
.type _start, @function
_start:
  la sp, __stack_top
 call main

1:
  /* mpause is the Coral bare-metal completion instruction. */
  .word 0x08000073
  j 1b
.size _start, .-_start
