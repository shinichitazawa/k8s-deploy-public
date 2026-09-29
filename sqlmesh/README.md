# sqlmesh — bronze から silver / gold を作る

[SQLMesh](https://github.com/TobikoData/sqlmesh) で変換を組み、クエリは Trino(`trino/`)に投げる。
`flow-ingest` が書く `bronze.netobserv_flows` を入力に、`silver` と `gold` を毎時更新する。

```
bronze.netobserv_flows ──▶ silver.flows ──┬─▶ gold.workload_traffic_hourly
  (flow-ingest が書く)     (1 行 = 1 フロー) ├─▶ gold.namespace_traffic_hourly
                                            ├─▶ gold.node_traffic_hourly
                                            └─▶ gold.dns_health_hourly
```

## 構成

| | |
|---|---|
| sqlmesh | 0.236.2(2026-09-25 時点の PyPI 最新) |
| image | `python:3.14.7-slim-trixie` を**ダイジェスト固定**。依存は `requirements.lock`(63 パッケージ、ハッシュ固定) |
| 実行 | CronJob `sqlmesh`(毎時 35 分)。`flow-compact`(毎時 20 分)の後 |
| エンジン | `trino.trino.svc.cluster.local:8080`、catalog `lakehouse`。秘密値は無い |
| 状態 | 共有 PostgreSQL の DB `sqlmesh`。**Trino は state connection に使えない**(公式ドキュメントに明記) |
| 配置 | `lab-worker-14`(lock が x86_64 向け) |
| ArgoCD | app `sqlmesh`、wave 58(Trino 50 / 共有 PG 30 の後) |

`sqlmesh` namespace は `lakehouse` app(wave 25)が作る。共有 PG の Secret が
`enable_cross_namespace_secret` でこの ns に出るため、infra(30)より前に存在していないと
postgres-operator の sync が失敗する(lakekeeper と同じ理由)。

## モデル

`base/models/<層>/<モデル名>.sql`。ファイルの場所はモデル名を決めないが(`MODEL (name ...)` が決める)、
**層ごとのディレクトリに置いて名前と一致させる**。

| モデル | 種別 | 内容 |
|---|---|---|
| `silver.flows` | INCREMENTAL_BY_TIME_RANGE | 1 行 = 1 フロー。プロトコル名、duration、RTT を ms に、ノード跨ぎ / 外部との通信の判定を足す。ワークロード名は Pod 名ではなく **owner**(Deployment 名など)を使うので、Pod の入れ替わりで系列が切れない |
| `gold.workload_traffic_hourly` | 同上 | 時間 × 送信元/宛先ワークロード × プロトコル |
| `gold.namespace_traffic_hourly` | 同上 | 時間 × namespace 間。k8s の情報が無い側は `(external)` |
| `gold.node_traffic_hourly` | 同上 | 時間 × ノード間。RTT の平均と p95 付き |
| `gold.dns_health_hourly` | 同上 | 時間 × 呼び出し元。件数、レイテンシ(平均 / p95 / 最大)、NXDomain 数 |

ConfigMap のキーに `/` は使えないため、`kustomization.yaml` では `models__gold__xxx.sql` のように
`__` 区切りで並べ、`prepare.sh` がディレクトリに戻す。**モデルを足したらここにも 1 行足す。**
足し忘れると、そのファイルは pod に入らない(kustomize は glob を解釈しない)。

## timestamp with time zone の罠

bronze の時刻列は `timestamp(6) with time zone`。**素の `TIMESTAMP` リテラルと比べると、
エラーにならず 0 件になる**(Trino がセッションのタイムゾーン=既定ではクライアントのゾーンで
解釈するため)。2026-09-25 に実測した。対処は 2 つとも入れてある。

- 接続設定で `timezone: UTC` を指定する
- モデルの絞り込みは `CAST(@start_ts AS TIMESTAMP(6) WITH TIME ZONE)` で明示的に型を合わせる
  (`@start_ds` は `varchar` なので `TYPE_MISMATCH` で落ちる。こちらはエラーになるので気づける)

## CronJob が何をするか

```
sqlmesh plan prod --no-prompts --auto-apply   # git のモデル定義を反映(差分が無ければ何もしない)
sqlmesh run                                   # 期限の来た区間を埋める
```

**`plan --auto-apply` は破壊的変更も無確認で適用する。** モデルの列や式を変えると、SQLMesh は
その時点から backfill をやり直す。データ量が小さいので許容している(silver の 1 日ぶん 218 万行の
再構築が約 11 秒)。増えてきたら `plan` を人間の操作に戻すこと。

## Lakekeeper の soft-delete と噛み合わない点

このウェアハウスは **soft-delete(7 日で purge)** で作られている(`delete-profile: {type: soft,
expiration-seconds: 604800}`)。テーブルを削除しても 7 日間は残るため、**空になった namespace を
削除できない**(`NamespaceNotEmptyException`。`recursive` / `force` を付けても同じ)。

SQLMesh は環境を片付けるとき「ビューとテーブルを消す → スキーマを消す」順で動くので、
最後のスキーマ削除が必ず失敗する(2026-09-25 に実測。`sqlmesh destroy` が完走しない)。

`prod` だけを使うぶんには janitor が消すものが無いので影響しない。dev 環境を使うなら、
ウェアハウスを hard-delete に変えるか、残るスキーマを許容する必要がある。
**検証で作った `silver__dev_probe` / `gold__dev_probe` / `probe_sch` が空のまま残っており、
2026-10-02 に自動で消える。**

## 確認したこと(2026-09-25、手元から port-forward した Trino に対して)

- 5 モデルすべて作成。silver に 218 万行(**同じ時間窓の bronze と件数が完全一致**)、
  gold は 14.1k / 1.27k / 84 / 24 行。所要 17 秒
- Trino + Lakekeeper(REST カタログ)が SQLMesh の要求する DDL / DML をすべて満たす:
  CREATE SCHEMA / CTAS / CREATE (OR REPLACE) VIEW / MERGE / DELETE / ADD COLUMN / RENAME / COMMENT
- 検証で作った環境は削除した(上記のスキーマだけ soft-delete の都合で残っている)

**クラスタ内での実行は未検証。** マージ後に初回の CronJob を確認する。
