# DMA 跨 LOAD 请求流水化

## 行为

`MatrixDmaLoad` 的请求发射与返回写入分别按命令顺序推进。上一条
LOAD 的最后一个 burst 请求被 `AxiReadBurstCtrl` 接收后，即可启动
下一条 LOAD，不再等待上一条返回和写寄存器全部结束。下层 AR 暂存
保持请求顺序，AR 反压时不会越序，也不会改变等待握手的地址。

```text
LOAD B data:  发请求 -------- 接收返回 -------- 写寄存器完成
LOAD B scale:       发请求 ------------------ 接收返回 ---- 完成
```

此处只提前访问内存，LOAD 完成仍以最后一次寄存器写入为准。
scoreboard 继续等待该完成事件，MATMUL 不会因此提前读取未就绪数据。

全局读 burst outstanding 保持 16，写侧保持 4。LOAD 的 issue FIFO、
in-flight 描述符 FIFO 均保持深度 3，PC FIFO 保持深度 4。
PC FIFO 限制已接收但未完成的 LOAD 总数为 4，包括排队、发射和接收中
的命令；它不是额外允许 4 条执行中的 LOAD。队列满时照常反压。

## 返回边界

`AxiReadBurstCtrl` 的 burst 元数据新增一位 `burst_cmd_last_i`，标记
该 burst 是否为所属 LOAD 的最后一个。它与偏移信息一起入队，最终随
最后一个 R beat 产生寄存后的 `r_cmd_last_o`。AXI 仍使用单 ID 保序，
不增加乱序重排；`RLAST` 本身仍只表示一个 burst 结束。

接收侧使用 `read_cmd_last` 立即暂停下一个 R 握手，再由
`recv_cmd_data_done` 保持暂停。旧 LOAD 缓冲写完后，装入下一条
in-flight 描述符，更新寄存器编号、data/scale、行宽及行数，再恢复 R。
暂停覆盖 R 返回的一拍寄存延迟，防止后续 LOAD 数据进入旧命令缓冲。
这版允许命令交界有少量切换气泡，不追求返回侧零气泡。

## 错误语义

burst 错误报告后，当前 LOAD 停止继续写矩阵寄存器，清空剩余拼接数据；
已经写入的内容不回滚。仍按计划发完该 LOAD 的请求，并接收、丢弃其余
返回，直到本 LOAD 的尾拍到达，再汇报一次 fault。

错误完成不再依赖全局 `!read_busy`，因此已经发出的后续 LOAD 不会
让错误排空等待整个读子系统。后续命令按各自描述符恢复接收，不受前一条
fault 标志污染。PC 按命令顺序匹配；故障地址仍沿用现有的零值约定，
没有新增精确地址报告或回滚机制。

## 验证与复测

独立测试无需 CPU/Chisel 重新生成，依赖本机 `iverilog` 和 `vvp`：

```bash
cd /home/wjj/2-NPU/coralnpu
bash tests/cocotb/run_matrix_dma_load_overlap.sh
```

读深度 4、16 各运行 16 个场景，均已通过。检查包括跨 LOAD 的 AR
提前发射、outstanding 上限、4 条命令容量及反压、AR 背压稳定性、
AB/C/data/scale 写入与补零、短行拼接、非对齐、跨 4KB、多拍 burst、
错误出现在不同命令及 burst/beat、错误后继续处理后续 LOAD，以及带
在途请求复位后的重新运行。

延迟返回的连续行场景中，第二条 LOAD 在第 5 拍完成首次 AR 握手，
第一条 LOAD 在第 126 拍才给出完成通知。该数据仅用于证明重叠，
不是 DRAMsim3 GEMM 的性能结果。

完整 CPU/GEMM 回归和 DRAMsim3 性能复测待执行。先单独运行边界用例：

```bash
bazel test \
  //tests/cocotb:matrix_cpu_dma_multicreg_c_api_elf_multicreg_m65_n257_k128 \
  --test_output=streamed --nocache_test_results
```

通过后，再用与 680.755 MAC/cycle 基线相同的交织配置测量：

```bash
CORAL_DRAMSIM3_CONFIG="$PWD/tests/cocotb/CORAL_DDR4_32GBps_interleaved.ini" \
  bash tests/cocotb/run_matrix_dramsim3.sh gemm /tmp/coral_dram_load_overlap_gemm
```

CPU 测试中的退休检查允许后续 LOAD 的 R 已经返回，但仍要求当前命令
所需的返回全部完成、整体返回顺序正确，并在测试结束校验完整事务和结果。
