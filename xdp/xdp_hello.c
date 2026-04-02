// 定义段属性，告诉编译器把这个函数放在专门的 section 里
#define SEC(NAME) __attribute__((section(NAME), used))

// 核心约定：定义我们的 Helper 函数！
// 假设我们在刚才的跳转表里，把 bpf_helper_log 安排在索引 1 的位置 (ID = 1)
static void (*bpf_helper_log)(const char *msg) = (void *) 1;

SEC("xdp")
int hello_xdp(void *ctx) {
    // 字符串 "HI" (包含结尾的 \0，共 3 字节：0x48, 0x49, 0x00)
    // Clang 在开优化时，会极其聪明地把它当成一个整数压入栈中
    char msg[] = "HI";
    
    // 调用 Helper，传入指针
    bpf_helper_log(msg);
    
    // 返回 42
    return 42;
}