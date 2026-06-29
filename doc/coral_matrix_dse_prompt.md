# Coral Matrix DSE Prompt

You are an architecture DSE assistant.  
Your task is to analyze and explore the design space of the **Coral matrix subsystem** described below.

If any existing RTL in the repository appears inconsistent with this prompt, **follow this prompt as the architecture freeze for DSE**, not the partially-migrated integration code.

---

## 1. Mission

Build a design-space exploration study for Coral's matrix subsystem, with emphasis on:

- matrix local storage organization
- matrix DMA bandwidth / latency hiding
- compatibility between local storage and the matrix compute backend
- performance / area / energy tradeoffs

This is **not** a generic CPU cache DSE problem.  
This is a **matrix-register-file + DMA + matrix compute backend** DSE problem.

---

## 2. Architecture Freeze

Use the following architecture as the DSE target.

### 2.1 Top-level structure

Assume the long-term Coral matrix datapath is:

```text
Scalar Core -> Matrix Control / CSR
                    |
                    v
               MatrixCore
                    |
      +-------------+-------------+
      |                           |
      v                           v
 MatrixRegFile <-> MatrixDma <-> DRAM (AXI master)
                    |
                    v
             WS Matrix Compute Backend
```

Do **not** model the matrix memory path as going through the normal scalar LSU / DTCM path.

### 2.2 Matrix register classes

There are `8` architecturally visible matrix registers encoded with `3 bits`:

- `000..011` -> `tr0..tr3`
- `100..111` -> `acc0..acc3`

Interpretation:

- `tr*` are tile registers used mainly for matrix inputs such as `A/B`
- `acc*` are accumulator registers used mainly for `C` / output accumulation

### 2.3 Matrix local storage capacity

Do **not** assume the matrix local storage size is fixed.

The matrix register file size is a DSE target.

Treat the following as design variables:

- tile register count
- acc register count
- tile register capacity
- acc register capacity
- tile/acc capacity ratio

The current repository should only be used as evidence that:

- there are separate `tile` and `acc` register classes
- tile rows and acc rows have different widths
- DMA accesses the matrix storage in beat-granular units

### 2.4 Logical data geometry

Use the current int8-oriented compute target:

- tile logical shape: `32 x 64 x int8`
  - 32 rows
  - 64 bytes per row
  - 512 bits per row
- acc logical shape: `32 x 32 x int32`
  - 32 rows
  - 128 bytes per row
  - 1024 bits per row

Therefore:

- tile row beat count = `ceil(tile_row_bytes / dma_beat_bytes)`
- acc row beat count = `ceil(acc_row_bytes / dma_beat_bytes)`

### 2.5 Physical baseline for MatrixRegFile

Do **not** freeze any single matrix SRAM macro size.

Instead, use the following as the **baseline organization style**:

- one logical register maps to one SRAM macro

This organization style should be compared against more internally banked alternatives.

Do **not** treat the RTL shadow copies used for convenience as true silicon storage overhead.

### 2.6 DMA / DRAM interface baseline

Assume:

- AXI data width is a DSE parameter
- read outstanding depth baseline = `4`
- write outstanding depth baseline = `1`
- read response ordering = `single ID`, `in-order`

The matrix DMA directly accesses DRAM through AXI master.

### 2.7 Matrix load/store semantics

The DMA must support at least:

1. whole-register load/store
2. shaped normal load/store
3. shaped transpose load/store

Use the following semantics:

- `stride` unit = **bytes**
- element width encoding:
  - `00 -> 8-bit`
  - `01 -> 16-bit`
  - `10 -> 32-bit`
  - `11 -> 64-bit`

General shaped addressing model:

- normal:
  - `addr(row, col) = base + row * stride + col * elem_bytes`
- transpose:
  - `addr(row, col) = base + col * stride + row * elem_bytes`

### 2.8 Compute backend freeze

Use the following compute-side interpretation:

- dataflow = `WS (Weight Stationary)`
- target tile shape = `M = 32`, `N = 32`
- current primary reduction depth = `K <= 64`
- two tile-source operands + one accumulator destination

Treat this as the intended practical Coral backend, even if parts of the current RTL are still under migration.

---

## 3. What To Ignore

Ignore or de-prioritize the following when doing first-stage DSE:

- legacy direct-memory wrapper interfaces
- partially-migrated integration mismatches between Chisel wrapper and Verilog DMA
- debug-only or bring-up-only datapaths
- full CPU cache hierarchy effects
- scalar LSU resource sharing details
- exact exception / ROB retirement logic
- vector unit coupling

Also ignore the RTL shadow arrays used for whole-register convenience reads when estimating final SRAM area.

---

## 4. DSE Goals

Your first-stage DSE should answer:

1. What matrix local storage size and tile/acc split are well matched to the `32x32, K<=64` backend?
2. Is `one-register-one-macro` a good baseline organization style, or should Coral move toward more internal banking?
3. Is AXI read outstanding depth `4` enough?
4. What part of the design is most likely to bottleneck first:
   - local storage capacity
   - local storage bandwidth
   - DRAM bandwidth
   - DMA latency hiding
   - PE utilization

---

## 5. Parameters To Sweep

### 5.1 Mandatory sweeps

Sweep at least the following:

- tile register count
- acc register count
- tile register size
- acc register size
- AXI beat width
- read outstanding depth
- PE array scale
- reduction width / K support

### 5.2 Strongly recommended sweeps

Also evaluate:

- one-register-one-macro vs multi-bank-per-register
- tile/acc capacity ratio
- tile row width and acc row width
- double buffering on or off
- DMA command queue depth
- partial overlap between DMA and compute

### 5.3 Second-stage sweeps

Only after first-stage conclusions:

- multiple AXI IDs
- out-of-order read response handling
- write outstanding depth > 1
- finer banking inside each register
- more aggressive scaling of tile / acc register counts

---

## 6. Required Outputs

Produce results in a way that is useful for architecture decisions.

At minimum, report:

- total area
- matrix local SRAM area only
- matrix local SRAM leakage power
- matrix local SRAM dynamic read energy
- matrix local SRAM dynamic write energy
- tile load latency
- acc load/store latency
- PE utilization
- DRAM bandwidth demand
- sensitivity to outstanding depth
- sensitivity to local storage size
- qualitative bottleneck diagnosis

Also include:

- which parameter appears most leverageable
- which parameter appears over-provisioned
- which parameter appears under-provisioned

---

## 7. Modeling Guidance

When in doubt, model Coral as a **scratchpad-managed matrix engine**, not as a cache-managed CPU extension.

That means your analysis should focus on:

- storage capacity
- storage bandwidth
- bank conflicts
- port pressure
- refill / drain traffic
- overlap between DMA and compute

More specifically:

- tile registers primarily feed source operands
- acc registers primarily hold accumulation state and outputs
- DMA traffic is burst-oriented
- matrix storage is software-managed / instruction-managed

---

## 8. Recommended Evaluation Angles

Please analyze from at least these three angles:

### 8.1 Capacity-centric

What total matrix local storage size is enough for the current matrix backend and data reuse strategy?

### 8.2 Bandwidth-centric

Given:

- parameterized AXI beat width
- shaped / strided load support
- read outstanding baseline = 4

is the system likely to be DRAM-limited, DMA-limited, or local-storage-writeback-limited?

### 8.3 Organization-centric

Compare:

1. baseline:
   - one logical register = one SRAM macro
2. candidate:
   - each logical register internally banked at beat or row granularity

Focus on whether extra banking is justified by performance or overlap gain.

---

## 9. Deliverable Format

Please return your DSE study in the following format:

1. **Architecture recap**
   - restate the target architecture you used
2. **Assumptions**
   - list all explicit assumptions
3. **Knobs**
   - list all swept parameters
4. **Metrics**
   - list all output metrics
5. **Findings**
   - key conclusions, bottlenecks, and tradeoffs
6. **Recommendations**
   - what Coral should keep
   - what Coral should resize
   - what Coral should defer
7. **Next-step experiments**
   - what should be explored in stage 2

---

## 10. Reference Materials

If you want conceptual guidance, these are relevant:

- MAESTRO
  - <https://arxiv.org/abs/1805.02566>
- Gemmini
  - <https://arxiv.org/abs/1911.09925>
- ZigZag
  - <https://arxiv.org/abs/2007.11360>
- A Configurable and Efficient Memory Hierarchy for Neural Network Hardware Accelerator
  - <https://arxiv.org/abs/2404.15823>
- OpenGeMM
  - <https://arxiv.org/abs/2411.09543>
- Hybrid Systolic Array Accelerator with Optimized Dataflow for Edge Large Language Model Inference
  - <https://arxiv.org/abs/2507.09010>
- AccLLM
  - <https://arxiv.org/abs/2505.03745>

Local project references:

- `doc/coral_matrix_dse_target.md`
- `doc/matrix_dma_spec.md`
- `doc/REFERENCE/CUTEv2_zh.md`
- `coralnpu/hdl/verilog/matrix/PE.md`

---

## 11. One-Sentence Summary

You are exploring the design space of a Coral matrix subsystem built around:

`a tile/acc matrix register file + parameterized-width AXI DMA + direct DRAM access + 32x32 WS matrix backend with K<=64`.
