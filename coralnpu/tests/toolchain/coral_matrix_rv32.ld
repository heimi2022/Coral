/* Memory layout used by MatrixCoreMiniAxi and CoralNPU's RV32 core. */

MEMORY {
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
  DTCM (rw)  : ORIGIN = 0x00010000, LENGTH = 32K
  EXTMEM (rw): ORIGIN = 0x20000000, LENGTH = 4096K
}

ENTRY(_start)

__stack_size = 128;

SECTIONS {
  . = ORIGIN(ITCM);
  .text : ALIGN(4) {
    KEEP(*(.text.start))
    *(.text .text.*)
    . = ALIGN(4);
  } > ITCM

  .rodata : ALIGN(4) {
    *(.rodata .rodata.*)
    . = ALIGN(4);
  } > ITCM

  .data : ALIGN(4) {
    *(.sdata .sdata.*)
    *(.data .data.*)
    . = ALIGN(4);
  } > DTCM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    . = ALIGN(4);
    __bss_end = .;
  } > DTCM

  . = ORIGIN(DTCM) + LENGTH(DTCM) - __stack_size;
  .stack (NOLOAD) : ALIGN(4) {
    __stack_bottom = .;
    . += __stack_size;
    __stack_top = .;
  } > DTCM

  . = ORIGIN(EXTMEM);
  .extdata : ALIGN(4) {
    *(.extdata .extdata.*)
  } > EXTMEM

  /DISCARD/ : {
    *(.comment)
    *(.note*)
    *(.eh_frame*)
  }
}
