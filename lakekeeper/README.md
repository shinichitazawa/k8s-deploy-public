# lakekeeper — Iceberg REST カタログ

S3 上の Iceberg テーブルのメタデータを管理する REST カタログ。クエリエンジンの Trino
(`trino/`)が `iceberg.catalog.type=rest` で接続する。

## 構成

| | |
|---|---|
| chart | `lakekeeper` 0.12.0(appVersion 0.13.3) |
| image | `quay.io/lakekeeper/catalog` を**ダイジェスト固定** |
| DB | infra の共有 PostgreSQL 17.2(DB `lakekeeper`) |
| S3 | **keyless**。SA annotation `eks.amazonaws.com/role-arn` |
| ArgoCD | app `lakekeeper`、wave 45 |

## 依存(wave 順)

1. `kro-rgds`(15) — RGD `AppCloudRole`
2. `lakehouse`(25) — **ns `lakekeeper`**、S3 バケット、keyless ロール
3. `infra`(30) — 共有 PG に DB `lakekeeper` とユーザ、ns `lakekeeper` へ資格情報 Secret
4. `lakekeeper`(45) — 本体

ns を `lakehouse` 側で作るのは、共有 PG のユーザ `lakekeeper.lakekeeper` が
`enable_cross_namespace_secret` により **ns `lakekeeper` に Secret を作る**ため。
infra(30)より前に ns が無いと postgres-operator が sync に失敗する(実際に踏んだ)。

## 注意点

**暗号鍵は必ず事前作成した Secret を指す。** 未指定だと chart は helm の lookup で鍵を
保持しようとするが、これは ArgoCD と非互換(argo-cd#5202)で、**同期のたびに鍵が変わり
保存済みシークレットが復号できなくなる**。`sealedsecret.yaml`(SealedSecret)で管理している。
鍵を失うと warehouse の設定が復号できなくなるので、sealed-secrets の鍵バックアップも重要。

**chart 0.4.0 からの作り直し。** 旧構成は image `latest-main` の 6 行で、S3 も DB も未設定だった。
**0.8 未満は AWS system identity(IRSA)に非対応**なので、keyless にするには更新が必須だった。

**ダイジェスト固定の書き方**: chart は `printf "%s:%s" repository tag` で image を組むため、
`repository` 末尾に `@sha256` を置き `tag` にダイジェスト本体を渡す。

**helm hook**: ArgoCD は `helm.sh/hook: test` の付いたリソースを適用しない(2026-09-21 確認:
aws-ebs-csi-driver の test 用 SA / ClusterRole など 4 つは、レンダリング結果にはあるがクラスタに無く、
Application の管理対象にも出ない)。したがって ArgoCD 経由なら test Pod は作られない。
`$patch: delete` は `kubectl apply -k` で直接当てたときのために残している。
DB migration Job は post-install/post-upgrade hook で、ArgoCD が hook として扱うため残す。

## 認証は無効

OIDC 未設定なので **誰でもカタログを操作できる**。Service は ClusterIP のみで
Ingress を張っていないため、現状はクラスタ内からしか届かない。tailnet に公開するなら
先に認証を有効にすること(Tailscale Ingress で HTTPS 公開する)。

UI は catalog 本体が `/ui` で配信する(別コンテナではない)。

## 初回のみ必要な操作

git では表現できない一回限りの API 操作が 2 つある。どちらも実施済み(2026-09-18)。

### 1. bootstrap

初期管理者と最初の project を作る。`POST /management/v1/bootstrap` に
`{"accept-terms-of-use": true}`。認証が無効なのでトークンは不要。
これを済ませないと warehouse を作れない。

### 2. warehouse の作成

| | |
|---|---|
| 名前 | `lakehouse` |
| id | `0fe192c6-b323-11f1-9126-4f6a4684570e` |
| 実体 | `s3://example-lakehouse-bucket/warehouse/` |
| 認証 | `aws-system-identity` + `assume-role-arn`(external-id 付き) |
| 削除 | soft(7 日で purge) |

**Iceberg REST の `{prefix}` は warehouse 名ではなく warehouse の UUID。**
`/catalog/v1/lakehouse/namespaces` は 400(`WarehouseIdIsNotUUID`)になる。

作成ペイロードと IAM の考え方は `lakehouse/base/iam-warehouse-role.yaml` を参照。
要点は「S3 権限は pod のロールではなく **assume 先のロール**に載せる」こと。
Lakekeeper は client へ一時クレデンシャルを vend するとき必ずロールを assume するため。

### 疎通確認(2026-09-18 実施)

`bronze` namespace を作り、テスト表を 1 つ作って削除した。表作成のレスポンスに
`ASIA…` で始まる **STS の一時クレデンシャルが vend されて返る**ところまで確認済み
(= AssumeRole チェーンと external-id が期待どおり機能している)。
