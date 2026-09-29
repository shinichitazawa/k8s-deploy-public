MODEL (
  name silver.flows,
  kind INCREMENTAL_BY_TIME_RANGE (time_column time_flow_start),
  partitioned_by (DAY(time_flow_start)),
  cron '@hourly',
  grain (time_flow_start, src_addr, src_port, dst_addr, dst_port, proto),
  audits (not_null(columns := (time_flow_start)))
);

SELECT
  time_flow_start,
  time_flow_end,
  date_diff('millisecond', time_flow_start, time_flow_end) AS duration_ms,
  src_k8s_host_name,
  dst_k8s_host_name,
  src_k8s_namespace,
  dst_k8s_namespace,
  COALESCE(src_k8s_owner_name, src_addr) AS src_workload,
  COALESCE(dst_k8s_owner_name, dst_addr) AS dst_workload,
  src_addr, src_port, dst_addr, dst_port,
  CASE proto WHEN 6 THEN 'TCP' WHEN 17 THEN 'UDP' WHEN 1 THEN 'ICMP' ELSE CAST(proto AS VARCHAR) END AS proto_name,
  bytes, packets,
  COALESCE(tcp_retrans_packets, 0) AS tcp_retrans_packets,
  COALESCE(pkt_drop_packets, 0) AS pkt_drop_packets,
  pkt_drop_latest_drop_cause,
  time_flow_rtt_ns / 1e6 AS rtt_ms,
  dns_name, dns_latency_ms, dns_flags_response_code,
  src_k8s_host_name IS NOT NULL AND dst_k8s_host_name IS NOT NULL
    AND src_k8s_host_name <> dst_k8s_host_name AS is_cross_node,
  src_k8s_namespace IS NULL OR dst_k8s_namespace IS NULL AS is_external
FROM bronze.netobserv_flows
WHERE time_flow_start BETWEEN CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)
                  AND CAST(@end_ts AS TIMESTAMP(6) WITH TIME ZONE)
