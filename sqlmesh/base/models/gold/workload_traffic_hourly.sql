MODEL (
  name gold.workload_traffic_hourly,
  kind INCREMENTAL_BY_TIME_RANGE (time_column hour),
  partitioned_by (DAY(hour)),
  cron '@hourly',
  audits (not_null(columns := (hour)))
);

-- ワークロード間の通信量。Pod 名ではなく owner(Deployment 名など)で集計するので、
-- Pod の入れ替わりで系列が切れない。
SELECT
  date_trunc('hour', time_flow_start) AS hour,
  src_k8s_namespace,
  src_workload,
  dst_k8s_namespace,
  dst_workload,
  proto_name,
  count(*) AS flow_count,
  sum(bytes) AS bytes,
  sum(packets) AS packets,
  sum(tcp_retrans_packets) AS tcp_retrans_packets,
  sum(pkt_drop_packets) AS pkt_drop_packets,
  count_if(is_cross_node) AS cross_node_flows
FROM silver.flows
WHERE time_flow_start BETWEEN CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)
                  AND CAST(@end_ts AS TIMESTAMP(6) WITH TIME ZONE)
GROUP BY 1, 2, 3, 4, 5, 6
