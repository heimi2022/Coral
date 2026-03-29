# Xuantie Public Repo Notes

这份说明只针对当前公开可获取的 `riscv-matrix-extension-spec` 仓库。

## 当前结论

- 顶层仓库执行 `git submodule update --init` 即可。
- 不建议在 `xuantie-gnu-toolchain/` 里继续执行 `git submodule update --init --recursive`。
- `xuantie-gnu-toolchain` 当前这个公开 commit 里，仍然带有两个 gitlink:
  - `riscv-libcc-runtime`
  - `riscv-musl`
- 这两个仓库对应的公开 URL 当前不可访问，所以递归拉取会报错。这是上游公开仓库状态问题，不是本地操作问题。

## 这会影响什么

- 会影响：
  - `make musl`
  - `stamps/build-libcc-runtime`
- 不影响当前阶段这些事情：
  - 阅读 `spec/` 里的矩阵扩展规范
  - 阅读顶层 `qemu/` 里的矩阵扩展模拟实现
  - 阅读顶层 `xuantie-gnu-toolchain/` 的构建框架
  - 先在 Coral 里规划矩阵 CSR / decode / execute / 编译链路

## 推荐使用方式

1. 把顶层 `spec/` 当 ISA 规范参考。
2. 把顶层 `qemu/` 当行为参考。
3. 把顶层 `xuantie-gnu-toolchain/` 当编译器组织方式参考。
4. 真到要做编译器集成时，再单独准备 `gcc` / `binutils` / `newlib` / `glibc` 源码，优先走 `./configure --with-gcc-src=...` 这种 out-of-tree 方式。

## 现有 RISC-V 编译器复用

- 当前机器已经有可直接使用的 bare-metal 工具链：
  - `/opt/riscv/bin/riscv64-unknown-elf-gcc`
- 这套工具链可以直接复用于：
  - Coral 当前 bare-metal / ELF / objdump / nm / 反汇编流程
  - 使用 `.insn` 手写自定义指令编码的实验
- 这套工具链不能直接替代玄铁 matrix 编译器能力的场景：
  - 直接识别玄铁矩阵扩展助记符
  - 直接支持玄铁矩阵 intrinsic / ABI / 编译器后端
- 所以现阶段建议：
  - 继续复用 `/opt/riscv`
  - 把玄铁仓库先作为规范、qemu 和编译器源码参考
  - 等 Coral 真要接入矩阵助记符或 intrinsic 时，再引入玄铁修改过的 binutils/gcc

## 当前本地清理策略

- 保留：
  - 顶层 `spec/`
  - 顶层 `qemu/`
  - 顶层 `xuantie-gnu-toolchain/` 框架仓库
- 删除：
  - `xuantie-gnu-toolchain/` 目录下未完整拉取、且当前复用 `/opt/riscv` 不需要的子源码目录
- 这样做的目的：
  - 避免半初始化 submodule 长期留在工作区里造成误判
  - 减少后续 `git status` / 文件树的干扰
  - 保留以后重新按需拉取 matrix 编译器源码的空间

## 以后如果需要再补源码

- 如果后面真的要接玄铁 matrix 编译器支持，优先按需补这些源码：
  - `riscv-binutils`
  - `riscv-gcc`
  - `riscv-gdb`
  - `riscv-newlib`
  - `riscv-glibc`
- 更推荐的方式不是重新堆很多子模块，而是直接把需要的源码单独 clone 到别处，然后用：
  - `./configure --with-gcc-src=...`
  - `./configure --with-binutils-src=...`
  - `./configure --with-newlib-src=...`

## 本地检查命令

```bash
git -C /home/wjj/2-NPU/riscv-matrix-extension-spec submodule status
git -C /home/wjj/2-NPU/riscv-matrix-extension-spec/xuantie-gnu-toolchain submodule status
```
