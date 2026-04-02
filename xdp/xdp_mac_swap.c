#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int xdp_mac_swap_tx(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    unsigned char tmp_mac[ETH_ALEN];

    // 使用 GCC 内置函数进行内存拷贝，避免引入外部 helper 或 libc
    __builtin_memcpy(tmp_mac, eth->h_source, ETH_ALEN);
    __builtin_memcpy(eth->h_source, eth->h_dest, ETH_ALEN);
    __builtin_memcpy(eth->h_dest, tmp_mac, ETH_ALEN);

    // XDP_TX 会将修改后的包从原网卡发出去
    return XDP_TX;
}

char _license[] SEC("license") = "GPL";