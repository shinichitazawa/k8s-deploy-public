MODEL (
  name gold.namespace_traffic_hourly,
  kind INCREMENTAL_BY_TIME_RANGE (time_column hour),
  partitioned_by (DAY(hour)),
  cron '@hourly',
  audits (not_null(columns := (hour)))
);

-- namespace 間の通信量。どのチーム/機能がどれだけ喋っているかを見る粒度。
SELECT
  date_trunc('hour', time_flow_start) AS hour,
  COALESCE(src_k8s_namespace, '(external)') AS src_k8s_namespace,
  COALESCE(dst_k8s_namespace, '(external)') AS dst_k8s_namespace,
  count(*) AS flow_count,
  sum(bytes) AS bytes,
  sum(packets) AS packets,
  sum(tcp_retrans_packets) AS tcp_retrans_packets,
  count_if(is_cross_node) AS cross_node_flows,
  count_if(is_external) AS external_flows
FROM silver.flows
WHERE time_flow_start BETWEEN CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)
                  AND CAST(@end_ts AS TIMESTAMP(6) WITH TIME ZONE)
GROUP BY 1, 2, 3
