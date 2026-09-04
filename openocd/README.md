# CoralNPU JTAG download flow

This directory contains the OpenOCD configuration and helper scripts for the
two-RISC-V JTAG chain used by the board.

## Targets

| Script target | OpenOCD target | TAP | IDCODE |
|---|---|---|---|
| `rvv` | `riscv.cpu` | `riscv.tap` | `0x04f5484d` |
| `n300` | `riscv2.cpu` | `aux.tap` | `0x10310a6d` |

The `rvv` target is the CoralNPU RVV CPU. The `n300` target is the second
RISC-V CPU identified as Nuclei System Technology by its JTAG ID.

## One-time setup

The OpenOCD 0.12 installation is expected at:

```text
/home/wjj/.local/bin/openocd
```

The scripts use `sudo` by default because USB permissions in WSL may not be
configured. Set `OPENOCD_USE_SUDO=0` after installing suitable udev rules.

## Each run

1. In Vivado on Windows, program the FPGA with the appropriate `.bit` file.
2. Close Vivado Hardware Manager and other programs using the J-Link.
3. In an elevated Windows PowerShell, find the J-Link BUSID:

   ```powershell
   usbipd list
   ```

4. Attach the J-Link to WSL:

   ```powershell
   .\attach_jlink.ps1 -BusId 1-4
   ```

   Replace `1-4` with the actual BUSID. The PowerShell window must be run as
   Administrator.

5. In WSL, verify the USB device:

   ```bash
   lsusb | grep 1366
   ```

6. Scan the JTAG chain:

   ```bash
   ./openocd/scan_jtag.sh
   ```

7. Download an ELF to the selected CPU:

   ```bash
   ./openocd/load_elf.sh rvv \
     /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/jtag_uart_hello.elf

   ./openocd/load_elf.sh n300 \
     /home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/user_n300.elf
   ```

   The script selects the target explicitly and obtains the resume address
   from the ELF header automatically.

8. When finished, release the J-Link from WSL in elevated PowerShell:

   ```powershell
   .\detach_jlink.ps1 -BusId 1-4
   ```

## Direct commands

The equivalent second-CPU command is:

```bash
sudo /home/wjj/.local/bin/openocd \
  -f /home/wjj/2-NPU/openocd/coralnpu-jlink.cfg \
  -c "init" \
  -c "targets riscv2.cpu" \
  -c "halt" \
  -c "load_image {/home/wjj/2-NPU/NPU/1-RTL/coral_jtag_uart_verified/user_n300.elf}" \
  -c "resume 0x140" \
  -c "shutdown"
```

`load_image` downloads loadable ELF segments into the CPU's memory. It is a
volatile RAM download: FPGA reconfiguration or power cycling requires the ELF
to be downloaded again.

## Troubleshooting

- No `1366:xxxx` in `lsusb`: the J-Link is not attached to WSL with usbipd.
- IDCODE is `0xffffffff` or `0x00000000`: check JTAG wiring, VTref, TRST, and
  reduce `adapter speed 500` to `100` in `coralnpu-jlink.cfg`.
- `riscv.cpu` reports vector support with `vlenb=16`; the second target's
  `misa` must be checked separately before running RVV instructions on it.
