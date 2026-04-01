# 静态指令映射表

## 寄存器

首先C函数入口会传入两个参数，a0（数据包指针）和 a1（跳转表基址）。

eBPF 规定 R1 是上下文（即数据包指针），这很完美，R1 = a0。

eBPF 寄存器,角色,映射到 RV32 寄存器,硬件 ABI 名称,备注说明
R0,返回值,x15,a5,运算时用 a5，直到遇到 EXIT 指令时，再把 a5 移回 a0。
R1,参数 1 (Ctx),x10,a0,天然对应 C 语言的第一个参数。
R2,参数 2,x11,a1,eBPF 调 Helper 时的传参。
R3,参数 3,x12,a2,eBPF 调 Helper 时的传参。
R4,参数 4,x13,a3,eBPF 调 Helper 时的传参。
R5,参数 5,x14,a4,eBPF 调 Helper 时的传参。
R6,局部变量,x18,s2,需要在 Prologue 中压栈保护。
R7,局部变量,x19,s3,需要在 Prologue 中压栈保护。
R8,局部变量,x20,s4,需要在 Prologue 中压栈保护。
R9,局部变量,x21,s5,需要在 Prologue 中压栈保护。
R10,只读栈帧指针,x8,s0 / fp,在 Prologue 中初始化，指向当前栈底。
(隐藏),跳转表基址,x9,s1,"核心！ Prologue 第一步：mv s1, a1。"
