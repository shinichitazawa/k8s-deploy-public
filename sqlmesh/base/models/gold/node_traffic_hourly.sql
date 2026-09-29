MODEL (
  name gold.node_traffic_hourly,
  kind INCREMENTAL_BY_TIME_RANGE (time_column hour),
  partitioned_by (DAY(hour)),
  cron '@hourly',
  audits (not_null(columns := (hour)))
);

-- ノード間の通信量。Tailscale 越しの往来がどれだけあるかを見る。
SELECT
  date_trunc('hour', time_flow_start) AS hour,
  src_k8s_host_name,
  dst_k8s_host_name,
  proto_name,
  count(*) AS flow_count,
  sum(bytes) AS bytes,
  sum(tcp_retrans_packets) AS tcp_retrans_packets,
  avg(rtt_ms) AS avg_rtt_ms,
  approx_percentile(rtt_ms, 0.95) AS p95_rtt_ms
FROM silver.flows
WHERE time_flow_start BETWEEN CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)
                  AND CAST(@end_ts AS TIMESTAMP(6) WITH TIME ZONE)
  AND src_k8s_host_name IS NOT NULL AND dst_k8s_host_name IS NOT NULL
GROUP BY 1, 2, 3, 4
