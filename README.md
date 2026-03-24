# Coral

Coral is a local hardware design workspace organized around RTL source code, simulation scripts, and synthesis scripts.

The repository currently contains:

- `1-RTL/`: RTL-related source trees, including `coralnpu/` and `picorv32/`
- `2-SIM/`: simulation testbench files and helper scripts
- `3-SYN/`: synthesis scripts and file lists

## Repository Layout

```text
.
├── 1-RTL/
│   ├── coralnpu/
│   └── picorv32/
├── 2-SIM/
│   ├── asic.f
│   ├── mac16_tb.sv
│   ├── run
│   └── runvd
└── 3-SYN/
    ├── filelist.f
    ├── run
    └── scripts/
```

## Quick Start

### RTL

Main source trees live under `1-RTL/`.

- `1-RTL/coralnpu/` includes the Coral NPU source tree
- `1-RTL/picorv32/` includes the PicoRV32 source tree

For details on Coral NPU itself, see:

- [`1-RTL/coralnpu/README.md`](/home/wjj/2-NPU/1-RTL/coralnpu/README.md)

### Simulation

Simulation helper scripts are under `2-SIM/`.

Typical commands:

```bash
cd 2-SIM
bash run
bash runvd
```

Current script behavior:

- `run` invokes `vcs` with file list `asic.f`
- `runvd` opens waveforms with `verdi`

### Synthesis

Synthesis helper scripts are under `3-SYN/`.

Typical command:

```bash
cd 3-SYN
bash run
```

The synthesis script currently calls Synopsys Design Compiler through `dc_shell-t`.

## Notes

- This repository is a working project workspace rather than a fully polished release package.
- Some historical simulation or synthesis file lists still appear to reference older paths and may need to be updated before use.
- Large generated simulation artifacts, Verdi outputs, and local IDE files are intentionally ignored by Git.

## Requirements

Tool availability depends on which part of the workspace you want to use. Based on the current scripts and source trees, you may need:

- `vcs`
- `verdi`
- `dc_shell-t`
- `bazel`
- Python 3

## Status

The current top-level repository history has been reset to a clean single-commit import of this workspace.
