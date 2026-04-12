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

### 函数

我将源文件的主要代码逻辑整理为三类函数，分别是判别，接受BPF指令决定要如何处理它；中间，被判决函数调用，但会获得更多信息进行决策；输出（emit），被前两者调用，向缓存添加具体的rv32指令。

#### 输出（emit）函数

emit 系列函数的名字来自编译器和 JIT 的常见术语，凡是以 emit 开头的函数，都属于“代码生成”阶段的辅助函数。最底层的 emit(...) 是一般通用接口，实现非常简单，接收一条已经编码好的 RISC-V 指令，并把它放进当前 JIT 上下文对应的位置。但另外有一类函数，由于固定的作用，任何 BPF 程序都会运行的通用段落，也将其设计为了emit函数。

##### 立即数处理

对于立即数，emit_imm32、emit_imm64。其关注的细节是兼容 RV32 为了简化硬件设计而特殊设计的指令集。RISC-V 的普通整数立即数编码位数较短，例如 `addi` 只能直接携带 12 位立即数，而更大的常量通常要先用 `lui` 装入高 20 位，再用 `addi` 补上低位。所以反而在代码中 64 位立即数的实现是更简洁的，因为这里并不需要一次性构造一个真正的 64 位硬件立即数，而是把 64 位值拆成高 32 位和低 32 位，分别调用已有的 32 位装载逻辑即可。由于使用 Rust 对这一流程进行了重构，立即数与不完全依赖运行时在栈上的临时组织，而可以通过编译阶段与生成阶段之间的协同来完成。其基本流程是：先由固件侧确定立即数所对应的存储位置，再由 AOT 侧依据这一映射关系完成具体放置。这样，程序中的特定常量便能够以一种预先约定的方式与固件内部状态建立稳定关联。该设计思路源于 LLVM 工具链能够在编译期生成各类调试表。它们用以描述编译产物与代码之间的对应关系，这说明编译阶段不仅能够完成代码生成本身，也能够同步建立一套结构化的映射信息。<之后最好找一下这方面的文章>。

如此设计的原因是希望减少固件与 XDP 程序之间较为昂贵的通信成本。在传统 XDP 运行流程中通过名为 MAP 的抽象结构完成。以广泛应用的环形队列（BPF_MAP_TYPE_RINGBUF）为例，eBPF 程序零拷贝的写入流程中至少需要访问两个 helper 程序，一个是申请 MAP 地址，另一个是提交数据更新指针，这显然存在函数调用开销。在本文介绍的流程当中，MAP 地址将在 AOT 时期放置在一个立即数当中，向缓存区写入立即数则采用检查器约束。<写到检查器哪一章引用下>。如此不涉及任何拷贝，在单片机内存允许的情况下采用内联函数，能够达到最大通信性能。

<可以画一个流程图>

该设计的优点在于，它将原本分散的立即数处理过程转化为一套统一、可验证的映射机制。一方面，固件与 XDP 程序可以共享一致的地址，从而减少运行时解释和协调的开销；另一方面，在单/双线程 MCU 环境下，这种共享映射也为两者之间提供了一种轻量的异步通信方式。与完全依赖动态处理的方案相比，该方法具有更好的确定性、可维护性以及实现上的简洁性。

##### 预处理（prologue）与后处理（epilogue）

预处理负责建立当前 JIT 函数的执行现场，同时也是[栈布局](#栈布局)被实际创建出来的阶段。它会先分配栈帧，再按既定顺序保存返回地址、帧指针以及后续会使用到的被调用者保存寄存器。与此同时，eBPF 中的函数指针与返回值寄存器也会在这里映射到 RV32 寄存器。

后处理负责撤销预处理建立的现场。它会先将 eBPF 的返回值放入 RISC-V 的返回寄存器，再按与预处理相反的顺序恢复保存过的寄存器，最后回收整个栈帧并返回。若当前路径是 tail call，则不直接返回上层调用者，而是在恢复现场后跳转到目标程序继续执行。这样既保持了调用约定的一致性，也满足了 eBPF tail call 的执行语义。
