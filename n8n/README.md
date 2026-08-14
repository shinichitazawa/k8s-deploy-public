# n8n — ワークフロー自動化(rpi0-hybrid)

新ハイブリッド k3s クラスタ(`rpi0-hybrid`: raspberrypi-0 CP + マルチクラウド outpost)に
**n8n** を single-main(regular mode)でデプロイする。素の kustomize manifest(公式 Helm chart は
存在しない / community 8gears chart は Valkey/worker 込みで single-main には過剰なため不採用)。

- image: `docker.n8n.io/n8nio/n8n:2.33.3`(multi-arch。raspberrypi-0=arm64 で native 稼働)
- DB: **infra 共有 Zalando PostgreSQL**(`shared-db.infra.svc.cluster.local:5432`、DB=`n8n`)。SSL 必須・self-signed。
- 暗号鍵: **Sealed Secrets**(`n8n-encryption-key`)。不変・安定であること。
- UI 公開: **Tailscale Ingress(HTTPS)** → `https://n8n.example.ts.net`。

## 構成

```
n8n/
  base/                # namespace / deployment(single-main) / service / (sealedsecret)
  overlays/rasp/       # + Tailscale Ingress(HTTPS)
```

## 依存(前提インフラ)

GitOps の sync-wave 順に投入される(`applications/platform-hybrid.yaml`):

| wave | app | 役割 |
|---|---|---|
| 5 | sealed-secrets | 暗号鍵 SealedSecret の復号 controller |
| 10 | postgres-operator | Zalando operator(`enable_cross_namespace_secret: true`) |
| 30 | infra(shared-db) | 共有 PostgreSQL。`infra/base/postgres.yaml` に `n8n.n8n` user/db を追記済み |
| 50 | **n8n** | 本体 |

- operator が n8n ns に Secret `n8n.n8n.shared-db.credentials.postgresql.acid.zalan.do`(username/password)を払い出す。deployment はこれを `secretKeyRef` で参照。

## デプロイ手順

1. **暗号鍵の封緘**(sealed-secrets controller 稼働後)。`base/sealedsecret.yaml` を再生成:
   ```bash
   KEY=$(openssl rand -hex 32)
   kubectl --context rpi0-hybrid -n n8n create secret generic n8n-encryption-key \
     --from-literal=N8N_ENCRYPTION_KEY="$KEY" --dry-run=client -o yaml \
   | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller \
       --format yaml > n8n/base/sealedsecret.yaml
   ```
   → `base/kustomization.yaml` の `- sealedsecret.yaml` のコメントを外す。
   **平文キーは commit しない**(ciphertext のみ)。鍵を失う/変えると既存 credential が復号不能。

2. **GitOps 同期**: main へ merge すると platform-hybrid ApplicationSet が wave 順に sync。
   手動確認は `kustomize build --enable-helm n8n/overlays/rasp`。

## 検証

```bash
K="kubectl --context rpi0-hybrid"
$K -n n8n get pods                         # Ready、log に暗号鍵警告なし・DB 接続 OK
$K -n n8n get secret | grep credentials    # operator 払い出し Secret
tailscale status | grep n8n                # device 出現
# → ブラウザで https://n8n.example.ts.net 初回セットアップ
```
Webhook を作る場合、外部 URL が `https://n8n.example.ts.net/webhook/...`(localhost でない)ことを確認。

## メモ

- `~/.n8n` は emptyDir(Postgres 使用のため SQLite 永続不要)。大きな binary データを filesystem mode で
  扱うなら `N8N_DEFAULT_BINARY_DATA_MODE=filesystem` + local-path PVC へ差し替える。
- pod は raspberrypi-0 に固定(cloud outpost は zero-scale/spot で揮発するため)。
- スケールが要れば queue mode(Redis/Valkey + worker)へ移行可(暗号鍵は全 pod で共有)。
