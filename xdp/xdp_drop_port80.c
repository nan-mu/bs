#include <bpf_helpers.h>
#include <bpf_endian.h>

#define BLOCKED_PORT 80

SEC("xdp")
int xdp_drop_tcp_port(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    // 检查是否为 TCP 协议
    if (ip->protocol != IPPROTO_TCP)
        return XDP_PASS;

    // 解析 TCP 头 (这里简单起见，假设 IP 头没有 Option 字段，长度固定)
    struct tcphdr *tcp = (void *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
        return XDP_PASS;

    // 检查目的端口是否为 80 (注意网络字节序转换)
    if (tcp->dest == bpf_htons(BLOCKED_PORT)) {
        return XDP_DROP;
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";