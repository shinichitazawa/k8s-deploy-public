/*
    Lightweight SIP (RFC 3261) tracker: observes SIP signaling on port 5060
    (UDP or TCP) in the TC path and aggregates per-flow request/response
    counts, the latest method and the latest response code.
*/

#ifndef __SIP_TRACKER_H__
#define __SIP_TRACKER_H__

#include "utils.h"

#define SIP_PORT 5060
#define SIP_READ_LEN 12

#define SIP_METHOD_INVITE 1
#define SIP_METHOD_REGISTER 2
#define SIP_METHOD_ACK 3
#define SIP_METHOD_BYE 4
#define SIP_METHOD_CANCEL 5
#define SIP_METHOD_OPTIONS 6
#define SIP_METHOD_OTHER 7

static __always_inline u8 sip_l4_header_len(pkt_info *pkt, void *data_end) {
    switch (pkt->id->transport_protocol) {
    case IPPROTO_TCP: {
        struct tcphdr *tcp = (struct tcphdr *)pkt->l4_hdr;
        if (!tcp || ((void *)tcp + sizeof(*tcp) > data_end)) {
            return 0;
        }
        return tcp->doff * sizeof(u32);
    }
    case IPPROTO_UDP: {
        struct udphdr *udp = (struct udphdr *)pkt->l4_hdr;
        if (!udp || ((void *)udp + sizeof(*udp) > data_end)) {
            return 0;
        }
        // touching the header keeps the verifier's packet-pointer state
        if (bpf_ntohs(udp->len) < SIP_READ_LEN) {
            return 0;
        }
        return sizeof(struct udphdr);
    }
    }
    return 0;
}

static __always_inline void sip_update_flow(flow_id *id, u16 eth_protocol, u8 method,
                                            u16 resp_code) {
    sip_metrics *extra_metrics = bpf_map_lookup_elem(&aggregated_flows_sip, id);
    if (extra_metrics != NULL) {
        extra_metrics->end_mono_time_ts = bpf_ktime_get_ns();
        extra_metrics->messages += 1;
        if (method != 0) {
            extra_metrics->requests += 1;
            extra_metrics->latest_method = method;
        }
        if (resp_code != 0) {
            extra_metrics->responses += 1;
            extra_metrics->latest_resp_code = resp_code;
        }
        return;
    }
    u64 current_time = bpf_ktime_get_ns();
    sip_metrics new_flow;
    __builtin_memset(&new_flow, 0, sizeof(new_flow));
    new_flow.start_mono_time_ts = current_time;
    new_flow.end_mono_time_ts = current_time;
    new_flow.eth_protocol = eth_protocol;
    new_flow.messages = 1;
    if (method != 0) {
        new_flow.requests = 1;
        new_flow.latest_method = method;
    }
    if (resp_code != 0) {
        new_flow.responses = 1;
        new_flow.latest_resp_code = resp_code;
    }
    long ret = bpf_map_update_elem(&aggregated_flows_sip, id, &new_flow, BPF_NOEXIST);
    if (ret == -EEXIST) {
        sip_metrics *em = bpf_map_lookup_elem(&aggregated_flows_sip, id);
        if (em != NULL) {
            em->messages += 1;
        }
    }
}

static __always_inline int track_sip_packet(struct __sk_buff *skb, pkt_info *pkt,
                                            u16 eth_protocol) {
    if (pkt->id->dst_port != SIP_PORT && pkt->id->src_port != SIP_PORT) {
        return 0;
    }
    void *data_end = (void *)(long)skb->data_end;
    u8 l4_len = sip_l4_header_len(pkt, data_end);
    if (!l4_len) {
        return 0;
    }
    u32 payload_offset = (long)pkt->l4_hdr - (long)skb->data + l4_len;
    char buf[SIP_READ_LEN];
    if (bpf_skb_load_bytes(skb, payload_offset, buf, SIP_READ_LEN) < 0) {
        return 0;
    }

    u8 method = 0;
    u16 resp_code = 0;
    if (buf[0] == 'S' && buf[1] == 'I' && buf[2] == 'P' && buf[3] == '/' && buf[4] == '2' &&
        buf[5] == '.' && buf[6] == '0' && buf[7] == ' ') {
        // SIP/2.0 <3-digit status>
        if (buf[8] >= '0' && buf[8] <= '9' && buf[9] >= '0' && buf[9] <= '9' && buf[10] >= '0' &&
            buf[10] <= '9') {
            resp_code = (buf[8] - '0') * 100 + (buf[9] - '0') * 10 + (buf[10] - '0');
        }
    } else if (buf[0] == 'I' && buf[1] == 'N' && buf[2] == 'V' && buf[3] == 'I') {
        method = SIP_METHOD_INVITE;
    } else if (buf[0] == 'R' && buf[1] == 'E' && buf[2] == 'G' && buf[3] == 'I') {
        method = SIP_METHOD_REGISTER;
    } else if (buf[0] == 'A' && buf[1] == 'C' && buf[2] == 'K' && buf[3] == ' ') {
        method = SIP_METHOD_ACK;
    } else if (buf[0] == 'B' && buf[1] == 'Y' && buf[2] == 'E' && buf[3] == ' ') {
        method = SIP_METHOD_BYE;
    } else if (buf[0] == 'C' && buf[1] == 'A' && buf[2] == 'N' && buf[3] == 'C') {
        method = SIP_METHOD_CANCEL;
    } else if (buf[0] == 'O' && buf[1] == 'P' && buf[2] == 'T' && buf[3] == 'I') {
        method = SIP_METHOD_OPTIONS;
    } else {
        // not a recognizable SIP message start (could be a continuation
        // segment on TCP); count nothing to keep the signal clean
        return 0;
    }

    sip_update_flow(pkt->id, eth_protocol, method, resp_code);
    return 0;
}

#endif /* __SIP_TRACKER_H__ */
