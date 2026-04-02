#ifndef __XDP_PROTOCOL_DEF_H
#define __XDP_PROTOCOL_DEF_H

/* 1. 以太网相关 (Ethernet) */
#ifndef ETH_ALEN
#define ETH_ALEN 6
#endif

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800     /* Internet Protocol packet  */
#endif

#ifndef ETH_P_IPV6
#define ETH_P_IPV6 0x86DD   /* IPv6 over bluebook        */
#endif

#ifndef ETH_P_ARP
#define ETH_P_ARP 0x0806    /* Address Resolution packet */
#endif

/* 2. IP 协议号 (IP Protocols) */
#ifndef IPPROTO_ICMP
#define IPPROTO_ICMP 1
#endif

#ifndef IPPROTO_TCP
#define IPPROTO_TCP 6
#endif

#ifndef IPPROTO_UDP
#define IPPROTO_UDP 17
#endif

#ifndef IPPROTO_ICMPV6
#define IPPROTO_ICMPV6 58
#endif

/* 3. 常见的 TCP 标志位 (TCP Flags) */
#ifndef TCP_FLAG_FIN
#define TCP_FLAG_FIN 0x01
#endif

#ifndef TCP_FLAG_SYN
#define TCP_FLAG_SYN 0x02
#endif

#ifndef TCP_FLAG_RST
#define TCP_FLAG_RST 0x04
#endif

#ifndef TCP_FLAG_ACK
#define TCP_FLAG_ACK 0x10
#endif

/* 4. ICMP 类型 */
#ifndef ICMP_ECHO
#define ICMP_ECHO 8         /* Echo Request */
#endif

#ifndef ICMP_ECHOREPLY
#define ICMP_ECHOREPLY 0    /* Echo Reply   */
#endif

#endif /* __XDP_PROTOCOL_DEF_H */