# eBPF → RV32 JIT 翻译手册

本文档描述 `jit_rv32.rs` 将 eBPF 字节码翻译为 RISC-V 32 位机器码的完整规则。

---

## 一、寄存器映射

eBPF 是 64 位 ISA，有 11 个通用寄存器 (R0–R10)。RV32 是 32 位，我们将每个 eBPF 寄存器映射到一个 RV32 寄存器，只使用低 32 位语义。

| eBPF 寄存器 | RV32 寄存器 | ABI 名 | 用途 |
|-------------|-------------|--------|------|
| R0  | x15 | a5 | 返回值（eBPF 程序运算结果） |
| R1  | x10 | a0 | 第 1 个函数参数（如 XDP ctx 指针） |
| R2  | x11 | a1 | 第 2 个函数参数 |
| R3  | x12 | a2 | 第 3 个函数参数 |
| R4  | x13 | a3 | 第 4 个函数参数 |
| R5  | x14 | a4 | 第 5 个函数参数 |
| R6  | x18 | s2 | callee-saved（跨 helper 调用保留） |
| R7  | x19 | s3 | callee-saved |
| R8  | x20 | s4 | callee-saved |
| R9  | x21 | s5 | callee-saved |
| R10 | x8  | s0/fp | 只读栈帧指针（eBPF 规范禁止写入） |

### 内部 scratch 寄存器（不映射 eBPF）

| RV32 寄存器 | ABI 名 | 用途 |
|-------------|--------|------|
| x5  | t0 | 立即数暂存、除法操作数暂存 |
| x6  | t1 | 字节序转换中间值 |
| x7  | t2 | 字节序转换中间值 |
| x9  | s1 | **helper 函数指针表基址**（由调用方在入口通过 a1 传入） |

---

## 二、调用约定与栈帧

### 2.1 Prologue（函数入口）

eBPF 程序被翻译为一个普通的 RV32 C 函数，签名约定为：

```c
uint32_t bpf_prog(void *ctx, void **helper_table);
//                 a0           a1
```

Prologue 做如下事情（共 11 条指令）：

```asm
addi  sp, sp, -32      # 开辟 32 字节保存 callee-saved 寄存器
sw    ra,  28(sp)      # 保存返回地址
sw    s0,  24(sp)      # 保存原帧指针
sw    s1,  20(sp)      # 保存 s1（helper 表指针使用前先保护）
sw    s2,  16(sp)      # 保存 eBPF R6
sw    s3,  12(sp)      # 保存 eBPF R7
sw    s4,   8(sp)      # 保存 eBPF R8
sw    s5,   4(sp)      # 保存 eBPF R9
addi  s0, sp, 32       # 设置新帧指针（= eBPF R10，只读）
mv    s1, a1           # 把 helper 表基址藏入 s1
addi  sp, sp, -512     # 再向下分配 512 字节作为 eBPF 栈空间
```

### 2.2 栈布局

```
高地址
┌─────────────────┐  ← s0 (eBPF R10 = fp)，eBPF 程序以此为基准做 [fp - N] 访问
│  ra   (28(sp')) │
│  s0   (24(sp')) │
│  s1   (20(sp')) │
│  s2   (16(sp')) │
│  s3   (12(sp')) │
│  s4   ( 8(sp')) │
│  s5   ( 4(sp')) │
├─────────────────┐  ← sp' = sp after first addi (保存区底部)
│                 │
│  512 字节       │  ← eBPF 栈（eBPF 指令通过 [s0 - offset] 访问）
│  eBPF stack     │
│                 │
└─────────────────┘  ← sp（当前栈顶）
低地址
```

> eBPF 规范：`R10` 是只读帧指针，合法访问范围为 `[R10 - 512, R10)`。
> 翻译后对应 `[s0 - 512, s0)`，即编译器分配的 512 字节区域。

### 2.3 Epilogue（函数出口）

```asm
addi  sp, sp, 512      # 释放 eBPF 栈
mv    a0, a5           # 把 eBPF R0 (a5) 移入 C 返回寄存器 a0
lw    ra,  28(sp)      # 恢复返回地址
lw    s0,  24(sp)      # 恢复帧指针
lw    s1,  20(sp)      # 恢复 s1
lw    s2,  16(sp)      # 恢复 R6
lw    s3,  12(sp)      # 恢复 R7
lw    s4,   8(sp)      # 恢复 R8
lw    s5,   4(sp)      # 恢复 R9
addi  sp, sp, 32       # 释放保存区
jalr  zero, ra, 0      # ret
```

---

## 三、eBPF 指令 → RV32 翻译规则

以下列表中：
- `dst` = eBPF 目标寄存器对应的 RV32 寄存器
- `src` = eBPF 源寄存器对应的 RV32 寄存器
- `imm` = 指令中的 32 位立即数字段
- `off` = 指令中的 16 位偏移字段
- `t0/t1/t2` = 内部 scratch 寄存器

### 3.1 BPF_LD — 立即数加载

1. **`LD_DW_IMM` (0x18)** — 加载 64 位立即数（双字宽指令，占 16 字节）
   - 取低 32 位（第一条指令的 imm 字段），忽略高 32 位（RV32 无法表示）。
   - 翻译为 `lui dst, hi20` + `addi dst, dst, lo12`（若 imm 较小则只需一条 `addi`）。

2. **`LD_ABS_B/H/W/DW`** — 从数据包绝对偏移加载
   - 数据包基址保存在 `s0`（即 eBPF R10 / fp）。
   - B → `lbu a5, imm(s0)`
   - H → `lhu a5, imm(s0)`
   - W/DW → `lw a5, imm(s0)`

3. **`LD_IND_B/H/W/DW`** — 从 `src + imm` 偏移加载
   - `add t0, src, s0` → `lbu/lhu/lw a5, imm(t0)`

### 3.2 BPF_LDX — 寄存器间接加载

4. **`LD_B_REG` (0x71)** — `dst = *(u8*)(src + off)`
   - → `lbu dst, off(src)`

5. **`LD_H_REG` (0x69)** — `dst = *(u16*)(src + off)`
   - → `lhu dst, off(src)`

6. **`LD_W_REG` (0x61)** — `dst = *(u32*)(src + off)`
   - → `lw dst, off(src)`

7. **`LD_DW_REG` (0x79)** — `dst = *(u64*)(src + off)`（RV32 只取低 32 位）
   - → `lw dst, off(src)`

### 3.3 BPF_ST — 立即数存储

8. **`ST_B_IMM` (0x72)** — `*(u8*)(dst + off) = imm`
   - → `li t0, imm` + `sb dst, off(t0)`
   - （`li` 展开为 `lui+addi` 或单条 `addi`）

9. **`ST_H_IMM` (0x6a)** → `li t0, imm` + `sh dst, off(t0)`

10. **`ST_W_IMM` (0x62)** → `li t0, imm` + `sw dst, off(t0)`

11. **`ST_DW_IMM` (0x7a)** → `li t0, imm` + `sw dst, off(t0)`（低 32 位）

### 3.4 BPF_STX — 寄存器存储

12. **`ST_B_REG` (0x73)** — `*(u8*)(dst + off) = src`
    - → `sb dst, off(src)`

13. **`ST_H_REG` (0x6b)** → `sh dst, off(src)`

14. **`ST_W_REG` (0x63)** → `sw dst, off(src)`

15. **`ST_DW_REG` (0x7b)** → `sw dst, off(src)`（低 32 位）

### 3.5 BPF_ALU32 — 32 位算术逻辑

16. **`ADD32_IMM`** — `dst += imm`
    - → `li t0, imm` + `add dst, dst, t0`

17. **`ADD32_REG`** — `dst += src`
    - → `add dst, dst, src`

18. **`SUB32_IMM`** — `dst -= imm`
    - → `li t0, imm` + `sub dst, dst, t0`

19. **`SUB32_REG`** → `sub dst, dst, src`

20. **`MUL32_IMM`** → `li t0, imm` + `mul dst, dst, t0`（RV32M）

21. **`MUL32_REG`** → `mul dst, dst, src`

22. **`DIV32_IMM`** — 无符号除法，除零返回 0
    - imm == 0 → `mv dst, zero`
    - imm != 0 → `li t0, imm` + `divu dst, dst, t0`

23. **`DIV32_REG`** — 除零保护序列：
    ```asm
    beq src, zero, zero_path   # 若除数为零跳转
    divu dst, dst, src
    jal zero, after
    zero_path: mv dst, zero
    after:
    ```

24. **`MOD32_IMM`** — 无符号取模，除零保持 dst 不变
    - imm == 0 → 不发射任何指令
    - imm != 0 → `li t0, imm` + `remu dst, dst, t0`

25. **`MOD32_REG`** — 除零保护序列（跳过 `remu`，dst 保持原值）：
    ```asm
    beq src, zero, after
    remu dst, dst, src
    after:
    ```

26. **`OR32_IMM`** → `li t0, imm` + `or dst, dst, t0`

27. **`OR32_REG`** → `or dst, dst, src`

28. **`AND32_IMM`** → `andi dst, dst, imm`（imm 在 12 位内直接编码）

29. **`AND32_REG`** → `and dst, dst, src`

30. **`XOR32_IMM`** → `li t0, imm` + `xor dst, dst, t0`

31. **`XOR32_REG`** → `xor dst, dst, src`

32. **`LSH32_IMM`** → `slli dst, dst, (imm & 0x1F)`

33. **`LSH32_REG`** → `sll dst, dst, src`

34. **`RSH32_IMM`** — 逻辑右移 → `srli dst, dst, (imm & 0x1F)`

35. **`RSH32_REG`** → `srl dst, dst, src`

36. **`ARSH32_IMM`** — 算术右移 → `srai dst, dst, (imm & 0x1F)`

37. **`ARSH32_REG`** → `sra dst, dst, src`

38. **`NEG32`** → `sub dst, zero, dst`

39. **`MOV32_IMM`** → `li dst, imm`（展开为 `lui+addi`）

40. **`MOV32_REG`** → `addi dst, src, 0`（即 `mv dst, src`）

41. **`LE`** — 转为小端字节序
    - RV32 目标本身即小端，**不发射任何指令**（no-op）。

42. **`BE`** — 转为大端字节序（手动字节交换）
    - 16 位：`(dst & 0xFF) << 8 | (dst >> 8) & 0xFF`，用 `andi`/`slli`/`srli`/`or` 实现。
    - 32/64 位：4 字节 bswap，用 10 条 shift/and/or 指令实现（无 rev8 扩展时）。

### 3.6 BPF_ALU64 — 64 位算术逻辑（在 RV32 上降级为 32 位）

eBPF ALU64 指令在 RV32 上**只操作低 32 位**，翻译规则与对应的 ALU32 指令完全相同：

| eBPF ALU64 | 翻译 |
|---|---|
| `ADD64_IMM/REG` | 同 `ADD32_IMM/REG` |
| `SUB64_IMM/REG` | 同 `SUB32_IMM/REG` |
| `MUL64_IMM/REG` | 同 `MUL32_IMM/REG` |
| `DIV64_IMM/REG` | 同 `DIV32_IMM/REG`（含除零保护） |
| `MOD64_IMM/REG` | 同 `MOD32_IMM/REG`（含除零保护） |
| `OR/AND/XOR/LSH/RSH/ARSH` | 同 32 位版本 |
| `NEG64` | `sub dst, zero, dst` |
| `MOV64_IMM` | `li dst, imm` |
| `MOV64_REG` | `mv dst, src` |

> **设计取舍**：放弃高 32 位是有意为之。目标平台（ESP32-C3 等嵌入式 RV32）内存有限，
> 且 XDP 程序中绝大多数有效值（指针、包长度、返回码）均在 32 位范围内。

### 3.7 BPF_JMP — 跳转指令

所有跳转使用**两遍编译**：Pass 1 在目标位置写占位符 `0`，Pass 2 回填实际字节偏移。

#### 无条件跳转

43. **`JA`** — 无条件跳转到 `pc + off + 1`
    - → `jal zero, byte_offset`（J-type，±1MB 范围）

#### 比较跳转（带立即数时先 `li t0, imm`）

44. **`JEQ_IMM/REG`** — `if dst == src/imm: jump`
    - → `beq dst, src, offset`（funct3 = 0b000）

45. **`JNE_IMM/REG`** — `if dst != src/imm: jump`
    - → `bne dst, src, offset`（funct3 = 0b001）

46. **`JGT_IMM/REG`** — 无符号 `if dst > src/imm: jump`
    - 等价于 `src < dst`（bltu）
    - → `bltu src, dst, offset`（funct3 = 0b110，注意操作数对调）

47. **`JGE_IMM/REG`** — 无符号 `if dst >= src/imm: jump`
    - → `bgeu dst, src, offset`（funct3 = 0b111）

48. **`JLT_IMM/REG`** — 无符号 `if dst < src/imm: jump`
    - → `bltu dst, src, offset`（funct3 = 0b110）

49. **`JLE_IMM/REG`** — 无符号 `if dst <= src/imm: jump`
    - 等价于 `src >= dst`（bgeu）
    - → `bgeu src, dst, offset`（操作数对调）

50. **`JSGT_IMM/REG`** — 有符号 `if dst > src/imm: jump`
    - 等价于 `src < dst`（blt）
    - → `blt src, dst, offset`（funct3 = 0b100，操作数对调）

51. **`JSGE_IMM/REG`** — 有符号 `if dst >= src/imm: jump`
    - → `bge dst, src, offset`（funct3 = 0b101）

52. **`JSLT_IMM/REG`** — 有符号 `if dst < src/imm: jump`
    - → `blt dst, src, offset`（funct3 = 0b100）

53. **`JSLE_IMM/REG`** — 有符号 `if dst <= src/imm: jump`
    - 等价于 `src >= dst`（bge）
    - → `bge src, dst, offset`（操作数对调）

54. **`JSET_IMM/REG`** — `if (dst & src/imm) != 0: jump`
    - → `and t1, dst, src` + `bne t1, zero, offset`

#### JMP32

`JEQ_IMM32` 至 `JSLE_REG32` 的翻译规则与上述 JMP 完全相同，因为 RV32 的
比较指令本身就是 32 位操作。

### 3.8 BPF_CALL — 函数调用

55. **`CALL`（src=0）— 外部 helper 调用**

    eBPF `call imm` 调用编号为 `imm` 的 helper 函数。

    ```asm
    lw   t0, (imm*4)(s1)   # 从 helper 表中取出函数指针
    jalr ra, t0, 0          # 调用
    mv   a5, a0             # 把 C 返回值 a0 放入 eBPF R0 (a5)
    ```

    **helper 表结构**：s1 指向一个 `u32[]` 数组，索引即 helper ID，
    每个槽存放对应函数的 32 位地址。调用方在入口时通过 `a1` 传入该表基址。

    **参数传递**：eBPF R1–R5 已映射到 a0–a4，与 RV32 调用约定完全吻合，
    无需额外的参数搬运。

56. **`CALL`（src=1）— BPF-to-BPF 本地调用**

    调用同一 eBPF 程序内的另一个函数（子程序）。需要额外保护
    callee-saved 的 eBPF 寄存器 R6–R9，因为被调用方可能修改它们：

    ```asm
    # 保存 R6–R9
    addi sp, sp, -16
    sw   sp, s2, 12    # R6
    sw   sp, s3,  8    # R7
    sw   sp, s4,  4    # R8
    sw   sp, s5,  0    # R9

    jal  zero, target  # 跳转到目标 eBPF PC（Pass 2 回填偏移）

    # 恢复 R6–R9
    lw   s2, sp, 12
    lw   s3, sp,  8
    lw   s4, sp,  4
    lw   s5, sp,  0
    addi sp, sp, 16
    ```

    > 为什么要额外保存？RV32 ABI 中 s2–s5 是 callee-saved，
    > 被调用的子函数会在其自己的 prologue/epilogue 中保存/恢复它们。
    > 但 eBPF 规范要求 R6–R9 在 CALL 后保持不变（对于调用方而言），
    > 所以我们在调用点再包一层保护，确保语义正确。

57. **`TAIL_CALL`** — 不支持，返回错误。

58. **`EXIT`** — eBPF 程序退出
    - → `jal zero, epilogue_offset`（无条件跳转到 Epilogue，Pass 2 回填）

---

## 四、跳转偏移的两遍编译

### 为什么需要两遍？

eBPF 分支目标用相对指令数表示（`off` 字段），而 RV32 B-type/J-type
用相对字节数表示。问题在于：一条 eBPF 指令可能翻译为 1~10+ 条 RV32
指令（例如带立即数的分支要先 `li t0, imm`），所以目标 eBPF PC 对应的
RV32 字节地址在 Pass 1 扫描到分支指令时尚未确定。

### Pass 1：记录 PatchSite

每遇到分支/跳转指令：
1. 记录当前 word 索引（`word_idx`）和目标 eBPF PC（`target_pc`）。
2. 在 `out[word_idx]` 写入占位符 `0`。
3. 继续翻译后续指令，同时记录每条 eBPF 指令对应的 `pc_locs[i]`。

### Pass 2：resolve_jumps 回填

```
byte_offset = (pc_locs[target_pc] - patch.word_idx) * 4
```

- 对 B-type 分支：重新用 `enc_b(byte_offset, rs2, rs1, funct3, 0x63)` 编码。
- 对 JAL：重新用 `enc_j(byte_offset, zero, 0x6F)` 编码。

两遍编译保证了所有跳转的字节偏移都是精确的，无论目标指令翻译后有多少条 RV32 词。

---

## 五、Map 读写

> **当前版本**：Map 访问通过 **helper 调用**实现，而非直接内存操作。
> 这是 eBPF 规范的标准做法，也适合嵌入式场景（Map 数据结构维护在 C 侧）。

### 5.1 标准 helper 路径

eBPF 中 Map 操作统一通过 helper 函数完成：

| eBPF helper | 编号 | 功能 |
|---|---|---|
| `bpf_map_lookup_elem` | 1 | 根据 key 查询 value 指针 |
| `bpf_map_update_elem` | 2 | 写入 key-value 对 |
| `bpf_map_delete_elem` | 3 | 删除 key |

eBPF 程序调用 `call 1`（`CALL imm=1`），翻译后展开为：

```asm
lw   t0, 4(s1)        # helper 表第 1 项 = bpf_map_lookup_elem 的地址
jalr ra, t0, 0        # 调用
mv   a5, a0           # 返回值（void* 或 NULL）存入 eBPF R0
```

调用前，eBPF 程序已按照 ABI 将参数放入 R1–R5（= a0–a4）：
- `a0` = map 文件描述符指针（或 map 对象指针，视实现而定）
- `a1` = key 指针

### 5.2 直接内存访问（静态 Map）

对于**编译期已知地址的静态 Map**（参见 `docs/static_int_map.md`），
eBPF 程序可以用 `LD_DW_IMM` 将 Map 的 32 位地址加载到寄存器，然后用
`LD_W_REG` / `ST_W_REG` 直接读写：

```
# 伪 eBPF：读取静态 Map 中偏移 0 处的值
LD_DW_IMM r1, 0x3FFC_0000   # Map 基址（编译期常量）
LD_W_REG  r0, [r1 + 0]      # 读取
```

翻译后：

```asm
# LD_DW_IMM r1 -> a0
lui  a0, 0x3FFC0           # hi20
addi a0, a0, 0             # lo12 = 0

# LD_W_REG r0, [r1+0] -> lw a5, 0(a0)
lw   a5, 0(a0)
```

### 5.3 Map 写入示例

```
# 伪 eBPF：向静态 Map 偏移 4 处写入立即数 42
LD_DW_IMM r1, 0x3FFC_0000
MOV32_IMM r2, 42
ST_W_REG  [r1 + 4], r2
```

翻译后：

```asm
lui  a0, 0x3FFC0      # Map 基址 -> a0 (eBPF R1)
addi a1, zero, 42     # 42 -> a1 (eBPF R2)
sw   a0, a1, 4        # *(a0+4) = a1
```

---

## 六、注意事项与限制

1. **64 位语义丢失**：所有 ALU64 操作只保留低 32 位。若 eBPF 程序依赖
   64 位溢出行为或高位数据，结果将不正确。

2. **`LD_DW_IMM` 高 32 位丢弃**：64 位立即数只保留低 32 位。

3. **`LD_DW_REG` / `ST_DW_REG`**：64 位内存操作降级为 32 位，高地址字不读写。

4. **`TAIL_CALL` 不支持**：嵌入式场景不需要尾调用链，直接报错。

5. **B-type 分支范围**：RV32 B-type 偏移范围 ±4KB，J-type (JAL) 范围 ±1MB。
   对于超长程序中的远跳转，需要改用 `lui+jalr` 序列（当前版本未处理，
   超范围时 Pass 2 会产生截断偏移）。

6. **helper 表索引**：`lw t0, (imm*4)(s1)` 要求 `imm*4` 在 12 位有符号范围内
   即 helper ID < 512，已覆盖所有已知 Linux/eBPF helper。

7. **原子操作**：`ST_W_XADD` / `ST_DW_XADD` 未实现（需要 RV32A 扩展）。
