# trino — レイクハウスのクエリエンジン

Lakekeeper(Iceberg REST カタログ)に繋ぎ、S3 上の Iceberg テーブルを SQL で読む。

## 構成

| | |
|---|---|
| chart | `trino` 1.42.2(2026-05-01。2026-09-21 時点の最新) |
| image | `trinodb/trino` **483**(2026-07-18。同時点の最新)を**ダイジェスト固定** |
| 形 | **単一ノード**。worker 0、coordinator がクエリも実行する |
| 配置 | `lab-worker-14` に固定 |
| 資源 | requests 500m / 4Gi、**limits 3 CPU / 5Gi**、JVM heap 3G |
| カタログ | `lakehouse`(Iceberg REST → Lakekeeper)、`tpch`(動作確認用) |
| 公開 | ClusterIP のみ |
| ArgoCD | app `trino`、wave 50(lakekeeper=45 の後) |

chart の既定 appVersion は 480 だが、本体だけ 483 に上げている。

## なぜ単一ノードか

対象データが小さい(NetObserv のフロー履歴)ことと、常設の `lab-worker-14` の空き
(2026-09-21 実測で 7.1 GiB)に収めるため。Dremio OSS は k8s の最小サポートが 8 CPU / 16 GB で
専用ノードが要ったが、Trino には明示の下限が無い。

## AWS の資格情報を持たない

`lakehouse` カタログは `iceberg.rest-catalog.vended-credentials-enabled=true` にしてある。
Lakekeeper が warehouse 用のロールを AssumeRole して作った一時クレデンシャルを、Trino が
テーブルごとに受け取って S3 を読む。**Trino の pod には IAM ロールも静的キーも無い。**
S3 の権限設計は `lakehouse/base/iam-warehouse-role.yaml` に集約されている。

- REST カタログの設定: https://trino.io/docs/current/object-storage/metastores.html
- S3 ファイルシステム: https://trino.io/docs/current/object-storage/file-system-s3.html
  (有効化のプロパティ名は `fs.s3.enabled`。旧名の `fs.native-s3.enabled` ではない)

Lakekeeper は認証が無効なので `iceberg.rest-catalog.security=NONE`。Lakekeeper に OIDC を
入れたら `OAUTH2` に変える。

## limits を必ず付ける

このクラスタの k3s は既定でシステム予約が無く、上限の無いワークロードがノードの CPU を
取り切って kubelet が飢える(Dremio で実際に踏んだ)。requests だけでなく limits も書く。

## helm hook

ArgoCD は `helm.sh/hook: test` の付いたリソースを適用しない(2026-09-21 確認:
aws-ebs-csi-driver の test 用 SA / ClusterRole など 4 つは、レンダリング結果にはあるがクラスタに無く、
Application の管理対象にも出ない)。したがって ArgoCD 経由なら test Pod(`trino-test-connection`)は作られない。
`$patch: delete` は `kubectl apply -k` で直接当てたときのために残している。
