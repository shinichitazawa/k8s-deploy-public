MODEL (
  name gold.dns_health_hourly,
  kind INCREMENTAL_BY_TIME_RANGE (time_column hour),
  partitioned_by (DAY(hour)),
  cron '@hourly',
  audits (not_null(columns := (hour)))
);

-- DNS の応答時間と失敗。agent の ENABLE_DNS_TRACKING で付く値を使う。
SELECT
  date_trunc('hour', time_flow_start) AS hour,
  COALESCE(src_k8s_namespace, '(external)') AS src_k8s_namespace,
  src_workload,
  count(*) AS query_count,
  avg(dns_latency_ms) AS avg_latency_ms,
  approx_percentile(dns_latency_ms, 0.95) AS p95_latency_ms,
  max(dns_latency_ms) AS max_latency_ms,
  count_if(dns_flags_response_code <> 'NoError') AS error_count,
  count_if(dns_flags_response_code = 'NXDomain') AS nxdomain_count
FROM silver.flows
WHERE time_flow_start BETWEEN CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)
                  AND CAST(@end_ts AS TIMESTAMP(6) WITH TIME ZONE)
  AND dns_latency_ms IS NOT NULL
GROUP BY 1, 2, 3
