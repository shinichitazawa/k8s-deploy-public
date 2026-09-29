# Business rules

このレイクハウスは自宅の Kubernetes クラスタ(rpi0-hybrid)の**実際のネットワーク通信**を扱う。

## データの出どころ

NetObserv の eBPF agent が全ノードでフローを採取し、flow-ingest が Iceberg に書き、
SQLMesh が毎時 silver / gold を作る。`flows` は silver 層で、1 行が 1 フロー。

## ノードは 2 台だけ

`raspberrypi-0`(Raspberry Pi、コントロールプレーン)と `lab-worker-14`(x86 のワーカー)。
**`is_cross_node = true` はこの 2 台の間の通信**で、Tailscale の WireGuard を経由する。
クラウドのノードは現在 0 台。

## 列の使い分け

- **ワークロード名は `src_workload` / `dst_workload` を使う。** Pod 名ではなく owner
  (Deployment 名など)なので、Pod が入れ替わっても系列が切れない。
- **プロトコルは `proto_name`。** 値は `TCP` / `UDP` / `ICMP` のいずれか、**またはそれ以外のプロトコル番号を文字列にしたもの**(例: IPv6-ICMP は `'58'`)。3 つだけだと思って絞ると他のトラフィックを落とす。数値のプロトコル番号の列は無い。
- **`src_k8s_namespace` が NULL の行はクラスタ外**。集計で見せるときは `(external)` などに
  置き換える。`is_external` でも判定できる。
- **`rtt_ms` は TCP のみ**。UDP や ICMP では NULL になる。
- **`dns_*` は DNS の応答を含むフローだけ**に値が入る。件数を数えるときは
  `dns_latency_ms IS NOT NULL` で絞る。

## 既知の性質

- **DNS の NXDomain が多い。** Kubernetes の検索ドメイン展開で、1 回の名前解決が
  複数回の失敗を伴うため。異常ではない。
- `tcp_retrans_packets` と `pkt_drop_packets` は 0 が正常。継続的に増えていれば調べる。

## 集計

通信量は cube `traffic` を使う(`flow_count` / `total_bytes` / `total_packets` /
`total_retrans` / `total_drops` / `avg_rtt_ms`)。時間軸は `time_flow_start`。

**gold 層の集計済みの表は、この意味層からは参照できない。** SQLMesh が
`gold.workload_traffic_hourly` などを作っているが、MDL のモデルとして公開していないため、
名前を書いても解決されない。時間別の集計も cube `traffic` の `time_flow_start` を使う。
