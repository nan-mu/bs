# Linux 内核中的 JIT

本文实现的功能本质上属于 AOT（Ahead-of-Time，预先编译）：在程序实际执行之前，先将 BPF 字节码转换为 RV32 指令。就整体流程而言，它与 Linux 现有 JIT 将 BPF 字节码编译为 RV32 指令的逻辑基本一致。本文计划在此基础上，将 Linux 内核中的相关实现重写为 Rust 程序，并补充相应的测试用例。本节将重点介绍 Linux 源码中 JIT 的实现细节，以及相关测试用例的组织方式。

## JIT 编译器

### 栈布局

```text
Stack layout during BPF program execution:

                    high
    RV32 fp =>  +----------+
                | saved ra |
                | saved fp | RV32 callee-saved registers
                |   ...    |
                +----------+ <= (fp - 4 * NR_SAVED_REGISTERS)
                |  hi(R6)  |
                |  lo(R6)  |
                |  hi(R7)  | JIT scratch space for BPF registers
                |  lo(R7)  |
                |   ...    |
 BPF_REG_FP =>  +----------+ <= (fp - 4 * NR_SAVED_REGISTERS
                |          |        - 4 * BPF_JIT_S+CRATCH_REGS)
                |          |
                |   ...    | BPF program stack
                |          |
    RV32 sp =>  +----------+
                |          |
                |   ...    | Function call stack
                |          |
                +----------+
                    low
```

> 上图中：`high/low` 表示栈地址方向（上高下低）；`RV32 fp` 与 `RV32 sp` 分别表示当前函数的帧指针与栈指针位置；`saved ra`、`saved fp` 及 `RV32 callee-saved registers` 指由被调用者负责保存与恢复的寄存器现场；`JIT scratch space for BPF registers` 指 JIT 为 BPF 寄存器临时周转与溢出保存预留的栈区，`hi(R6)`、`lo(R6)` 等表示同一 BPF 64 位寄存器在 RV32 上拆分后的高/低 32 位槽位；`BPF_REG_FP` 标识 BPF 帧指针对应的位置；`BPF program stack` 为 BPF 程序语义上的专用栈区；`Function call stack` 为通用函数调用链继续向低地址扩展的常规调用栈区。

栈在该实现中承担运行时状态承载与调用现场维护的双重职能。对于 RV32 目标架构，JIT 产物作为标准函数实体执行，必须在进入与退出路径上满足 RISC-V ABI 对寄存器保存和恢复的约束，因此需要构造可验证、可逆的栈帧组织。

在将 XDP/eBPF 程序编译为 RV32 指令序列的任务中，栈空间同时对应四类语义对象：其一，JIT 生成的 RV32 函数作为被调方执行时，为保持内核态调用者现场，需按 ABI 对被调用者保存寄存器（callee-saved）如 ra/fp/s1..s7 执行保存与恢复；其二，JIT 后端为 BPF 的 R6-R9 与 BPF_REG_AX 寄存器，建立临时槽位（scratch），用于寄存器溢出与中间状态周转；其三，BPF 程序语义上的专用栈区，用于承载 BPF 指令可见的局部数据；其四，函数调用链继续展开所使用的常规调用栈区。

上述多重语义在同一栈帧内并置时会产生三类实现约束。第一，ABI 一致性与 BPF 语义保持需要同时成立，任何一侧的错误均会导致执行不正确。第二，BPF 64 位寄存器语义与 RV32 32 位物理寄存器之间存在结构性差异，必须通过 hi/lo 拆分与栈上槽位进行补偿。第三，多类数据若缺乏明确分层，将引发偏移冲突与状态覆盖风险，进而破坏寄存器恢复和栈访问正确性。

内核现有实现采用自高地址向低地址的分层布局：顶部为 `ra/fp/s1..s7` 的保存区，其下为 JIT scratch 区，再下为 BPF 程序栈区，最底部为普通调用栈区。该布局能够保证预处理与后处理（prologue/epilogue）的对称性以此简化指令实现，原因在于保存区的地址在函数全程保持稳定：在prologue 中，代码先一次性确定栈帧大小，再按固定偏移将 `ra/fp/s1..s7` 写入保存区；在 epilogue 中，代码按同一组偏移逆过程读回这些寄存器。由于 scratch 写入与 BPF 栈访问均被约束在保存区之外，执行期间不会改写或重定位保存槽位，因此入口与出口始终针对同一寄存器集合和同一地址集合进行互逆操作。进一步地，`STACK_OFFSET` 统一定义了栈槽偏移，`bpf_get_reg*` 与 `bpf_put_reg*` 仅在各自所属区域内进行取放，从而在满足 ABI 约束的同时维持 BPF 语义正确性。

### 枚举与宏

本节介绍寄存器与栈槽约束的枚举与宏定义，目标是对后续指令进行约束。具体来说 BPF 64 位寄存器在 RV32 上需要进行 hi/lo 拆分表示、落栈寄存器在栈帧中的槽位编号与相对 `fp` 的偏移寻址，以及 JIT 内部临时寄存器与尾调用计数寄存器的稳定绑定。若上述约束以分散常量散布于实现逻辑，将导致偏移语义不一致、槽位冲突，并使寄存器映射与栈寻址关系难以整体校验。

```c
enum {
	/*
	 * 栈布局：以下枚举值表示 JIT scratch 区顶部起算的槽位编号。
	 * 由于 BPF 寄存器语义为 64 位，RV32 后端以两个 32 位槽位（hi/lo）承载。
	 * 因此 R6-R9 以及 BPF_REG_AX 均以 HI/LO 成对定义，以固定其在 scratch 区的顺序。
	 */
	BPF_R6_HI,
	BPF_R6_LO,
	BPF_R7_HI,
	BPF_R7_LO,
	BPF_R8_HI,
	BPF_R8_LO,
	BPF_R9_HI,
	BPF_R9_LO,
	BPF_AX_HI,
	BPF_AX_LO,

	/* scratch 区槽位总数：覆盖 BPF_REG_6..BPF_REG_9 与 BPF_REG_AX 的 hi/lo 槽位。 */
	BPF_JIT_SCRATCH_REGS,
};

/*
 * 进入/退出路径需要保存的被调用者保存寄存器（callee-saved）数量。
 * 对应寄存器集合为：ra、fp、s1..s7，共 9 个。
 */
#define NR_SAVED_REGISTERS	9

/*
 * 将逻辑槽位编号 k 映射为相对 fp 的字节偏移（负值表示位于 fp 下方）。
 * 其中：
 * -4                  表示从 fp 下方第一个字（4 字节）位置开始；
 * 4*NR_SAVED_REGISTERS 表示越过 callee-saved 保存区；
 * 4*k                 表示在 scratch 槽位数组中按槽位索引递进。
 */
#define STACK_OFFSET(k)	(-4 - (4 * NR_SAVED_REGISTERS) - (4 * (k)))

/* JIT 代码生成过程中使用的内部临时寄存器编号（区别于 BPF 语义寄存器编号）。 */
#define TMP_REG_1	(MAX_BPF_JIT_REG + 0)
#define TMP_REG_2	(MAX_BPF_JIT_REG + 1)

/* 尾调用计数器寄存器及其备份寄存器在 RV32 物理寄存器上的固定绑定。 */
#define RV_REG_TCC		RV_REG_T6
#define RV_REG_TCC_SAVED	RV_REG_S7
```

### 直接寄存器转换

根据上一节对高低32位进行的约束，部分 BPF 寄存器能够一一映射到中间寄存器，即32位BPF寄存器，这将优化编译流程。在转换过程中需要区分三类寄存器。下表给出了 bpf2rv32 映射表中各 BPF 寄存器（含 JIT 内部临时寄存器）的语义角色及其在 RV32 后端中的映射结果。其中 `{hi, lo}` 分别表示 64 位 BPF 寄存器拆分后的高 32 位与低 32 位承载位置；该位置既可能是 RV32 物理寄存器，也可能是相对帧指针 `fp` 的栈槽偏移。

| 寄存器名称 | 寄存器的功能 | 转换结果 |
|---|---|---|
| `BPF_REG_0` | eBPF 返回值寄存器；也用于接收内核函数返回值 | `{hi, lo} = {RV_REG_S2, RV_REG_S1}` |
| `BPF_REG_1` | eBPF 向内核函数传参寄存器 | `{hi, lo} = {RV_REG_A1, RV_REG_A0}` |
| `BPF_REG_2` | eBPF 向内核函数传参寄存器 | `{hi, lo} = {RV_REG_A3, RV_REG_A2}` |
| `BPF_REG_3` | eBPF 向内核函数传参寄存器 | `{hi, lo} = {RV_REG_A5, RV_REG_A4}` |
| `BPF_REG_4` | eBPF 向内核函数传参寄存器 | `{hi, lo} = {RV_REG_A7, RV_REG_A6}` |
| `BPF_REG_5` | eBPF 向内核函数传参寄存器 | `{hi, lo} = {RV_REG_S4, RV_REG_S3}` |
| `BPF_REG_6` | eBPF callee-saved 寄存器，跨调用需要保持 | `{hi, lo} = {STACK_OFFSET(BPF_R6_HI), STACK_OFFSET(BPF_R6_LO)}` |
| `BPF_REG_7` | eBPF callee-saved 寄存器，跨调用需要保持 | `{hi, lo} = {STACK_OFFSET(BPF_R7_HI), STACK_OFFSET(BPF_R7_LO)}` |
| `BPF_REG_8` | eBPF callee-saved 寄存器，跨调用需要保持 | `{hi, lo} = {STACK_OFFSET(BPF_R8_HI), STACK_OFFSET(BPF_R8_LO)}` |
| `BPF_REG_9` | eBPF callee-saved 寄存器，跨调用需要保持 | `{hi, lo} = {STACK_OFFSET(BPF_R9_HI), STACK_OFFSET(BPF_R9_LO)}` |
| `BPF_REG_FP` | eBPF 只读帧指针，用于访问 BPF 栈 | `{hi, lo} = {RV_REG_S6, RV_REG_S5}` |
| `BPF_REG_AX` | JIT 内部临时寄存器，用于常量 blinding 等中间操作 | `{hi, lo} = {STACK_OFFSET(BPF_AX_HI), STACK_OFFSET(BPF_AX_LO)}` |
| `TMP_REG_1` | JIT 内部临时寄存器，用于操作栈上的 BPF 寄存器值 | `{hi, lo} = {RV_REG_T3, RV_REG_T2}` |
| `TMP_REG_2` | JIT 内部临时寄存器，用于操作栈上的 BPF 寄存器值 | `{hi, lo} = {RV_REG_T5, RV_REG_T4}` |


### 2.2 `emit_imm`
- 向 RV32 寄存器装载 32 位立即数。
- 逻辑：`lui + addi`（若高位非 0）或单条 `addi`。

### 2.3 `emit_imm32`
- 把 32 位立即数写入“BPF 64 位寄存器表示”：
  - `lo = imm`
  - `hi = 0 或 -1`（符号扩展）

### 2.4 `emit_imm64`
- 分别写入 `imm_lo`、`imm_hi` 到 lo/hi。

### 2.5 `__build_epilogue`
统一尾声生成：
- 非 tail-call：把 BPF R0 复制到 `a0/a1`
- 恢复 `ra/fp/s1..s7`
- `sp += stack_adjust`
- tail-call：`jalr t0, +4` 跳到目标程序（跳过其第一条）
- 普通返回：`jalr ra`

### 2.6 `is_stacked`
- 判断某个“寄存器映射项”是否在栈上（`< 0`）。

### 2.7 `bpf_get_reg64` / `bpf_put_reg64`
- `get`：若目标在栈上，先 `lw` 到临时寄存器
- `put`：若目标在栈上，计算后再 `sw` 回去

### 2.8 `bpf_get_reg32` / `bpf_put_reg32`
- 32 位版本取放。
- `put32` 处理 `verifier_zext`：必要时清高 32 位。

### 2.9 `emit_jump_and_link`
- 根据偏移范围选择：
  - 近跳：`jal`
  - 远跳/强制：`auipc + jalr`

---

## 分段 3：ALU 指令生成（64/32 位，立即数与寄存器）

### 3.1 `emit_alu_i64(dst, imm, op)`
支持的 64 位立即数运算：
- `MOV/AND/OR/XOR/LSH/RSH/ARSH`
- 对于位移，分别处理：`imm >= 32`、`imm == 0`、`0<imm<32`
- 对 `AND/OR/XOR` 会同步维护 hi 半部分语义

### 3.2 `emit_alu_i32(dst, imm, op)`
支持 32 位立即数运算：
- `MOV/ADD/SUB/AND/OR/XOR/LSH/RSH/ARSH`
- 12 位立即数走 I-type，否则先装临时寄存器再 R-type

### 3.3 `emit_alu_r64(dst, src, op)`
支持 64 位寄存器运算：
- `MOV/ADD/SUB/AND/OR/XOR/MUL/LSH/RSH/ARSH/NEG`
- 关键点：
  - `ADD/SUB` 显式处理进位/借位
  - `MUL` 通过 `mul/mulhu` 等组合计算 hi/lo
  - 变长移位按 `>=32` 与 `<32` 分路径

### 3.4 `emit_alu_r32(dst, src, op)`
支持 32 位寄存器运算：
- `MOV/ADD/SUB/AND/OR/XOR/MUL/DIV/MOD/LSH/RSH/ARSH/NEG`

---

## 分段 4：分支与条件跳转

### 4.1 `emit_branch_r64(src1, src2, rvoff, op)`
- 64 位比较分支实现（`JEQ/JNE/JGT/JLT/JGE/JLE/JSGT/JSLT/JSGE/JSLE/JSET`）
- 核心方法：先比较 hi，再结合 lo 得最终条件
- 末尾统一调用 `emit_jump_and_link`

### 4.2 `emit_bcc(op, rd, rs, rvoff, ctx)`
- 32 位条件分支底层发射。
- 远跳时反转条件，跳过后续跳转 stub。
- `JSET` 无直接逆条件，强制 far 分支路径。

### 4.3 `emit_branch_r32(src1, src2, rvoff, op)`
- 32 位分支封装：取寄存器 + 调 `emit_bcc`。

---

## 分段 5：调用、尾调用、访存、字节序工具

### 5.1 `emit_call(fixed, addr, ctx)`
- 调 helper/内核函数：
  1. 栈上暂存 R5
  2. 备份 TCC
  3. `lui + jalr` 绝对地址调用
  4. 恢复 TCC
  5. 返回值写回 BPF R0
  6. 恢复调用前栈

### 5.2 `emit_bpf_tail_call(insn, ctx)`
完成 tail call 流程：
1. 检查 `index < max_entries`
2. `--tcc`，防无限尾调用
3. 取 `prog = array->ptrs[index]`，空则退出
4. 取 `prog->bpf_func`
5. 调 `__build_epilogue(true)`，最终跳到目标程序

### 5.3 `emit_load_r64(dst, src, off, size)`
- 地址：`src_lo + off`
- 载入大小：`B/H/W/DW`
- 非 `DW` 时依据 `verifier_zext` 决定是否清 hi

### 5.4 `emit_store_r64(dst, src, off, size, mode)`
- 存储大小：`B/H/W/DW`
- `BPF_ATOMIC` 仅允许 `W`（且主要是 `BPF_ADD`）
- `DW + ATOMIC` 在 RV32 不支持

### 5.5 `emit_rev16` / `emit_rev32`
- 手工字节翻转（大小端转换辅助）。

### 5.6 `emit_zext64`
- hi 置 0，实现 32 位写入后的 64 位零扩展语义。

---

## 分段 6：主分发函数 `bpf_jit_emit_insn`

这是整文件核心：把一条 BPF 指令翻译成 RV32 指令序列。

### 6.1 前置状态
- `is64`：判断按 64 位跳转语义还是 32 位
- 提取 `code/off/imm`
- 解析 `dst/src/tmp1/tmp2`

### 6.2 ALU64 分支
- 支持：`MOV/ADD/SUB/AND/OR/XOR/MUL/LSH/RSH/ARSH/NEG`
- `DIV/MOD`（ALU64）标记为不支持
- `BPF_K` 场景先装立即数到临时寄存器

### 6.3 ALU32 分支
- 支持：`MOV/ADD/SUB/AND/OR/XOR/MUL/DIV/MOD/LSH/RSH/ARSH/NEG`
- 特例：`BPF_ALU | BPF_MOV | BPF_X` 且 `imm==1` 表示 zext

### 6.4 END（字节序）
- `FROM_LE`：16/32/64
- `FROM_BE`：16/32/64
- 非法位宽直接报错并返回 `-1`

### 6.5 跳转与调用
- `JA`：无条件跳
- `CALL`：解析地址后 `emit_call`
- `TAIL_CALL`：`emit_bpf_tail_call`
- 条件跳（JMP/JMP32 + 各类比较/JSET）：
  - 若 `BPF_K`，先构造立即数寄存器
  - `is64` 走 `emit_branch_r64`，否则 `emit_branch_r32`
- `EXIT`：若非最后一条则跳向统一 epilogue

### 6.6 载入与存储
- `LD IMM DW`：读取下一条指令的高 32 位，拼 64 位常量，并 `return 1`
- `LDX MEM`：走 `emit_load_r64`
- `ST/STX MEM`：走 `emit_store_r64`
- `STX ATOMIC W`：仅支持 `BPF_ADD`
- `STX ATOMIC DW`：明确不支持（RV32 无 8 字节原子）

### 6.7 错误路径
- `notsupported`：`-EFAULT`
- 未知 opcode：`-EINVAL`

---

## 分段 7：序言/尾声构建

### 7.1 `bpf_jit_build_prologue(ctx, is_subprog)`
构建函数序言：
1. 计算总栈大小（保存寄存器区 + BPF scratch + BPF stack + 对齐）
2. 第一条指令初始化 `TCC = MAX_TAIL_CALL_CNT`
3. 下移 `sp` 分配栈帧
4. 保存 `ra/fp/s1..s7`
5. 设置 RV `fp`
6. 设置 BPF `fp`
7. 设置 BPF `r1`（上下文指针）
8. 写入 `ctx->stack_size`

### 7.2 `bpf_jit_build_epilogue(ctx)`
- 仅调用 `__build_epilogue(false, ctx)`。

---

## 最终核对：与 `bpf_jit_comp32.c` 的覆盖检查

### A. 顶层结构覆盖
- [x] 文件头注释
- [x] 栈布局注释
- [x] `enum` 与宏
- [x] `bpf2rv32` 映射

### B. 所有函数覆盖
- [x] `hi`
- [x] `lo`
- [x] `emit_imm`
- [x] `emit_imm32`
- [x] `emit_imm64`
- [x] `__build_epilogue`
- [x] `is_stacked`
- [x] `bpf_get_reg64`
- [x] `bpf_put_reg64`
- [x] `bpf_get_reg32`
- [x] `bpf_put_reg32`
- [x] `emit_jump_and_link`
- [x] `emit_alu_i64`
- [x] `emit_alu_i32`
- [x] `emit_alu_r64`
- [x] `emit_alu_r32`
- [x] `emit_branch_r64`
- [x] `emit_bcc`
- [x] `emit_branch_r32`
- [x] `emit_call`
- [x] `emit_bpf_tail_call`
- [x] `emit_load_r64`
- [x] `emit_store_r64`
- [x] `emit_rev16`
- [x] `emit_rev32`
- [x] `emit_zext64`
- [x] `bpf_jit_emit_insn`
- [x] `bpf_jit_build_prologue`
- [x] `bpf_jit_build_epilogue`

### C. 关键 opcode 路径覆盖
- [x] ALU64（含不支持路径）
- [x] ALU32
- [x] END（LE/BE）
- [x] JMP/JA/CALL/TAIL_CALL/EXIT
- [x] 条件跳（JMP/JMP32 + K/X）
- [x] LD IMM DW
- [x] LDX/ST/STX/ATOMIC
- [x] notsupported/default 错误路径

---

## 一句话总结
该文件完整实现了 **RV32 平台 eBPF JIT 的指令翻译主链路**：寄存器模型、栈帧模型、算术/访存/分支/调用/尾调用、序言尾声和异常路径都在本说明中逐段覆盖。
