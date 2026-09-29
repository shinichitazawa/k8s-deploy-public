# flow-ingest — NetObserv のフローを Iceberg に書く受け口

NetObserv の agent(`netobserv/`、hostNetwork の DaemonSet)に内蔵された FLP から
`write/grpc` でフローを受け取り、Lakekeeper(`lakekeeper/`)経由で Iceberg の
`lakehouse.bronze.netobserv_flows` に追記する。S3 の鍵は持たない(keyless)。

```
agent(FLP: enrich → lake) ──gRPC──▶ flow-ingest ──pyiceberg──▶ S3(Iceberg)
                                         │ REST(vended credentials)
                                         ▼
                                     Lakekeeper
```

## なぜ自作か

FLP 自身にも S3 出力(`encode/s3`)があるが、認証が**静的キーのみ**
(`pkg/pipeline/encode/encode_s3.go` が `credentials.NewStaticV4(accessKeyId, secretAccessKey, "")` を
ハードコード、2026-09-23 に upstream main で確認)。IRSA も STS も使えないので、keyless 方針に合わない。
OTel Collector の `awss3exporter` は keyless で書けるが、出力は OTLP JSON で Iceberg にはならず、
別の変換工程が要る。受信して Iceberg に書くだけなら Python 約 200 行で済むので自作した。

## 構成

| | |
|---|---|
| 受信 | gRPC `genericmap.Collector/Send`(FLP の `write/grpc` の相手)。`Any.value` に flow の JSON が入る |
| 書き込み | pyiceberg 0.12.0(+ pyiceberg-core 0.10.1)。60 秒または 20,000 行ごとに append |
| テーブル | `bronze.netobserv_flows`。**namespace ごと**無ければ起動時に作る。`day(time_flow_start)` でパーティション |
| image | `python:3.14.7-slim-trixie`(ダイジェスト固定)。依存は `requirements.lock`(43 パッケージ、ハッシュ固定) |
| 配置 | `lab-worker-14`(lock が x86_64 向け) |
| 状態 | `GET :8080/` が `received / written / flushes / failed_flushes / dropped / buffered / fail_streak / degraded` を返す。probe は `/livez`(詰まりのみ 503) |
| compaction | CronJob `flow-compact`(毎時 20 分)。Trino の `EXECUTE optimize` 他 |
| ArgoCD | app `flow-ingest`、wave 48(Lakekeeper 45 の後) |

**列の対応は `ingest.py` の `FIELDS`。** FLP のフィールド名を snake_case にし、ms の時刻は
`timestamp(6) with time zone` に直す。`FIELDS` に無いキーは `extra_json` に JSON でまとめて残す
(MAC アドレス等の `IGNORED` は捨てる)。新しい計測を agent に足したら、まず `extra_json` に現れる。

**`FIELDS` に足すと、既存テーブルにも列が増える。** 起動時にテーブルの列と突き合わせ、
足りない分を `update_schema().union_by_name()` で追加する(追加だけ。削除や型変更はしない)。
実運用の最初の 1 分で `DnsName` / `DnsErrno` / `IcmpType` / `IcmpCode` が `extra_json` に出たので、
この 4 つは列にした。

**パーティション付きテーブルへの書き込みには `pyiceberg-core`(Rust)が要る。** 無いと
`NotInstalledError` になる(ローカルで実際に踏んだ)。

## netobserv 側の変更(同じ PR)

- FLP の pipeline に `{"name": "lake", "follows": "enrich", write: grpc}` を追加。`enrich` の後なので
  `SrcK8S_*` / `DstK8S_*` が付いた状態で届く
- agent の `dnsPolicy` を `ClusterFirstWithHostNet` に変更。hostNetwork の既定(`ClusterFirst`)はホストの
  resolv.conf を使うため、Service 名を引けない

受け側が落ちていても agent は止まらない(FLP は送信エラーをログに出して次に進む)。その間のフローは失われる。

## 流量とファイル数、compaction

2026-09-23 時点で約 55 flows/s(agent 2 台、Prometheus `netobserv_node_flows_total` の 1h rate)。
60 秒ごとの flush だと 1 ファイル 3,000 行前後、**1 日 1,440 ファイル**になる。

これを CronJob `flow-compact`(毎時 20 分、`compact.sh`)でまとめる。Trino の REST API に
次の 3 文を順に投げる。CLI の jar を持ち込まないため、`curl` と `jq` だけで書いてある
(image は ghost-node-reaper と同じ `alpine/k8s`)。

```sql
ALTER TABLE <t> EXECUTE optimize
ALTER TABLE <t> EXECUTE expire_snapshots(retention_threshold => '7d')
ALTER TABLE <t> EXECUTE remove_orphan_files(retention_threshold => '7d')
```

**実測(2026-09-25、`bronze` に作った検証表で確認し削除済み)**: 500 行ずつ 12 回書いて
12 ファイル / 108,504 バイトにした表が、`optimize` 後に **1 ファイル / 14,132 バイト**になった。
行数は 6,000 のまま変わらない。ファイルが 1 つだけの表に対しては 217 ms で何も起こらない。

**`expire_snapshots` は 7 日経つまで効かない。** 上の検証ではスナップショットが 13 個残った
(すべて作成直後で保持期間内)。Trino の既定では `retention_threshold` を 7 日未満にできず、
短くするには catalog 側(`iceberg.expire-snapshots.min-retention`)を変える必要がある。

**書き込みと同時に走ると commit が競合しうる。** その場合 CronJob は失敗して終わり、次の回で
やり直す(`concurrencyPolicy: Forbid`、`backoffLimit: 1`)。受け口側も競合を 1 回だけ再試行する。

## 一時クレデンシャルの期限(2026-09-25 に踏んだ)

**Lakekeeper が vend する S3 の一時クレデンシャルは 1 時間で切れる**(`expiration-time` を実測)。
**pyiceberg 0.12.0 はこれを自動更新しない。** レスポンスに `client.refresh-credentials-endpoint` が
入っているが、実装は未了(apache/iceberg-python#3506 / #3751 が open の feature request)。

そのため最初のデプロイでは、**起動ちょうど 1 時間後に書き込みが止まり、8.5 時間ぶんのフローを失った**
(03:57 開始、04:57 が最後の行)。pod は Running のまま、probe も通り続けたので気づけなかった。

対処は 2 つ。

- **flush のたびに `catalog.load_table()` で読み直す。** 読み直すとクレデンシャルが vend し直される。
  1 分に 1 回の REST 呼び出しで済む。compaction のコミットも取り込むので競合しにくくもなる
- **`STALE_SECONDS`(既定 300 秒)書けていなければ `GET /` が 503 を返す。** probe が落ちて pod が
  入れ替わる。「動いているのに書いていない」状態で放置されないようにする

## メタデータの増え方(2026-09-28 に対処)

**Iceberg はコミットのたびに新しい `metadata.json` を積む。** カタログ(Lakekeeper)の仕様ではなく
Iceberg の設計で、Glue でも Hive でも同じように増える。60 秒ごとに append するこの構成では
1 日 1,440 版になる。

実測(2026-09-28、`bronze.netobserv_flows`):

| | |
|---|---|
| スナップショット | 3,572 |
| データファイル | 34(300 MB)← compaction が効いている |
| S3 のメタデータオブジェクト | **10,566** |

`expire_snapshots` は保持期間が 7 日あるため、それまで何も減らない。そこで**スナップショットの
保持とは別軸の**テーブルプロパティで `metadata.json` の版数を抑える。

```
write.metadata.delete-after-commit.enabled = true
write.metadata.previous-versions-max       = 20   (METADATA_VERSIONS_MAX で変更可)
```

`ingest.py` がテーブル作成時に設定し、既存テーブルにも起動時に当てる(値が違う場合だけ)。

**検証(専用テーブルで実施、削除済み)**: `previous-versions-max=3` で 8 回 append したところ、
**スナップショットは 8 のまま**、`metadata_log` は 3、S3 上の `metadata.json` も 3 になった。
スナップショットもタイムトラベルも失われない。

**既存の約 3,500 個はすぐには消えない。** このプロパティが刈るのは metadata_log に載っている版で、
それより古いものは既に log から外れた孤児になっている。孤児は `flow-compact` が毎時実行する
`remove_orphan_files` が拾うが、こちらも保持期間が 7 日なので、減り始めるのは 2026-10-02 以降。

## 失敗時の挙動

- **失敗した行はバッファに戻す。** 上限は `MAX_BUFFER_ROWS`(既定 100,000 行)で、超えたら古い方から
  捨てて `dropped` に数える。Lakekeeper が一時的に落ちてもデータは失わない
- **probe(`/livez`)が落ちるのは「詰まり」だけ。** 1 回の flush が `STALE_SECONDS`(既定 300 秒)
  返ってこない状態を指す。**書けないこと自体では落とさない**。落とすと pod が入れ替わって
  バッファに抱えた行が失われるうえ、入れ替えても Lakekeeper の障害は直らない
- 書けているかは `GET /` の `degraded`(連続 `FAIL_STREAK_LIMIT` 回=既定 3 失敗)と
  `fail_streak` / `buffered` / `dropped` で見る
- 失敗したら次の周期まで待つ。**行数で起きる flush も同じ間隔を守る**(戻した行でバッファが
  上限のままなので、そのままだと 1 行受けるごとに再試行してしまう)
- 書き込みの失敗を gRPC の送り主には返さない(送られたフローの中身は正しいため)
- append のコミット競合(Trino の optimize 等と重なった場合)は、メタデータを読み直して 1 回だけやり直す
- SIGTERM でバッファを書き切ってから終了する(`terminationGracePeriodSeconds` 既定 30 秒)

**実測(2026-09-25、ローカル)**: `FLUSH_ROWS` を 200 にして 600 件送りながら Lakekeeper を落とすと、
25 秒で失敗は 3 回だけ(1 行ごとの再試行は起きない)、`degraded: true`、`/livez` は 200 のまま、
700 行がバッファに残った(`dropped` は 0)。戻すと 1,100 行すべてが書かれ、`fail_streak` は 0 に戻った。

## 確認したこと(2026-09-23、ローカル)

同じイメージ・同じ `prepare.sh` / `ingest.py` を read-only rootfs / uid 1000 のコンテナで動かし、
port-forward した Lakekeeper に対して 1,000 件送って 1 回で append、Trino から 800 件のテスト表を読んで
列型・パーティション(`time_flow_start_day`)・`extra_json` の中身を確認した。
テスト表は削除済み。**クラスタ内で agent から届くところはマージ後に確認する。**
