/*
    TCP retransmission tracking via the tcp:tcp_retransmit_skb tracepoint.
    The flow_id is built from the tracepoint arguments (not the skb) because
    on the transmit path the L2/L3 headers are not populated yet.
*/

#ifndef __TCP_RETRANS_H__
#define __TCP_RETRANS_H__

#include "utils.h"

// Kernels >= ~6.10 give tcp_retransmit_skb its own event struct (an err field
// was added), named trace_event_raw_tcp_retransmit_skb in BTF. Define a local
// CO-RE shape (the ___local suffix is stripped for BTF matching) so field
// offsets relocate against the running kernel.
struct trace_event_raw_tcp_retransmit_skb___local {
    struct trace_entry ent;
    const void *skbaddr;
    const void *skaddr;
    int state;
    __u16 sport;
    __u16 dport;
    __u16 family;
    __u8 saddr[4];
    __u8 daddr[4];
    __u8 saddr_v6[16];
    __u8 daddr_v6[16];
} __attribute__((preserve_access_index));

static inline long tcp_retrans_lookup_and_update_flow(flow_id *id, u16 flags, u64 len) {
    tcp_retrans_metrics *extra_metrics = bpf_map_lookup_elem(&aggregated_flows_tcp_retrans, id);
    if (extra_metrics != NULL) {
        extra_metrics->end_mono_time_ts = bpf_ktime_get_ns();
        extra_metrics->packets += 1;
        extra_metrics->bytes += len;
        extra_metrics->latest_flags |= flags;
        return 0;
    }
    return -1;
}

SEC("tracepoint/tcp/tcp_retransmit_skb")
int tcp_retransmit_skb(struct trace_event_raw_tcp_retransmit_skb___local *args) {
    if (do_sampling == 0) {
        return 0;
    }

    u16 family = BPF_CORE_READ(args, family);
    u16 eth_protocol;
    flow_id id;
    __builtin_memset(&id, 0, sizeof(id));

    if (family == AF_INET) {
        eth_protocol = ETH_P_IP;
        __builtin_memcpy(id.src_ip, ip4in6, sizeof(ip4in6));
        __builtin_memcpy(id.dst_ip, ip4in6, sizeof(ip4in6));
        bpf_probe_read_kernel(id.src_ip + sizeof(ip4in6), 4, args->saddr);
        bpf_probe_read_kernel(id.dst_ip + sizeof(ip4in6), 4, args->daddr);
    } else if (family == AF_INET6) {
        eth_protocol = ETH_P_IPV6;
        bpf_probe_read_kernel(id.src_ip, IP_MAX_LEN, args->saddr_v6);
        bpf_probe_read_kernel(id.dst_ip, IP_MAX_LEN, args->daddr_v6);
    } else {
        return 0;
    }

    id.src_port = BPF_CORE_READ(args, sport);
    id.dst_port = BPF_CORE_READ(args, dport);
    id.transport_protocol = IPPROTO_TCP;

    // respect the flow filtering feature when enabled
    bool skip = check_and_do_flow_filtering(&id, 0, 0, eth_protocol, NULL, 0);
    if (skip) {
        return 0;
    }

    struct sk_buff *skb = (struct sk_buff *)BPF_CORE_READ(args, skbaddr);
    u64 len = 0;
    if (skb != NULL) {
        len = BPF_CORE_READ(skb, len);
    }

    long ret = tcp_retrans_lookup_and_update_flow(&id, 0, len);
    if (ret == 0) {
        return 0;
    }

    // no existing entry: create one
    u64 current_time = bpf_ktime_get_ns();
    tcp_retrans_metrics new_flow;
    __builtin_memset(&new_flow, 0, sizeof(new_flow));
    new_flow.start_mono_time_ts = current_time;
    new_flow.end_mono_time_ts = current_time;
    new_flow.eth_protocol = eth_protocol;
    new_flow.packets = 1;
    new_flow.bytes = len;
    ret = bpf_map_update_elem(&aggregated_flows_tcp_retrans, &id, &new_flow, BPF_NOEXIST);
    if (ret == -EEXIST) {
        tcp_retrans_lookup_and_update_flow(&id, 0, len);
    }
    return 0;
}

#endif /* __TCP_RETRANS_H__ */
