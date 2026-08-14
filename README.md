# k8s-deploy-public

自前 k3s（Raspberry Pi control-plane + マルチクラウド worker）での検証に使った構成ファイルの公開ミラーです。Zenn の検証記事から参照するために、プライベートリポジトリから該当ディレクトリを抽出しています。

## 記事との対応

| ディレクトリ | 内容 | 関連記事 |
|---|---|---|
| `cluster-autoscaler/` | Cluster Autoscaler を AWS / GCP / Azure の 3 クラウドで keyless に動かす values・RBAC | 自前 k3s の Cluster Autoscaler を 3 クラウドで keyless に動かす |
| `azure-workload-identity-webhook/` | azure-workload-identity webhook（token/env 自動注入） | 同上 |
| `azure/` `gcp/` | k3s worker ノード用 VMSS / MIG の Terraform モジュール（spot・providerID・cloud-init） | オンプレ k3s に 6 クラウドの outpost ノードを接続する ほか |
| `cilium/` | Cilium(kube-proxy replacement) の values・overlay | Cilium 関連の各記事 |
| `tailscale/` | Tailscale Kubernetes operator の構成 | Tailscale auth key の自動 rotation ほか |
| `kro/` | Kro ResourceGraphDefinition（複合リソースの抽象化） | Kro と Crossplane、どちらを選ぶか |
| `netobserv/` | NetObserv eBPF Agent の direct-FLP 構成 | NetObserv eBPF Agent |
| `n8n/` | n8n（共有 PostgreSQL / Tailscale Ingress / keyless Bedrock） | n8n の AI Agent を Bedrock / Vertex / Azure で組む差分 ほか |
| `llm-ab-test/` `litellm/` `keda/` | OSS LLM の並行 A/B 比較（LiteLLM Router / KEDA scale-to-zero） | OSS LLM 4 つを LiteLLM + EKS + KEDA で A/B 比較する |
| `pod-identity-webhook/` | self-hosted IRSA 用 pod-identity-webhook | 自前 k3s で IRSA を再現する |
| `external-secrets/` | External Secrets Operator | Tailscale auth key の自動 rotation |

## 注意事項

- **環境固有の値はダミーに置換しています**: AWS アカウント ID（`111111111111`）、Azure の subscription / tenant / client ID（`00000000-…` 等）、tailnet 名（`example.ts.net`）、Tailscale IP（`100.64.0.10`）、LAN IP（`192.0.2.x` — RFC 5737 のドキュメント用アドレス）。そのまま apply しても動きません。ご自身の値に読み替えてください。
- `*.tfvars` は含まれません（`*.tfvars.example` を参照）。secrets は SealedSecret / External Secrets 経由で、平文の秘密情報はリポジトリに存在しません。
- 各ディレクトリの `base/charts/` は upstream Helm chart の vendored コピーです（改変がある場合は各 README に記載）。
- 元リポジトリの履歴は含みません（抽出時点のスナップショットです）。

## ライセンス

vendored chart はそれぞれの upstream ライセンスに従います。それ以外は MIT です。
