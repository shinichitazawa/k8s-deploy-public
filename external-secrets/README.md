# external-secrets

[External Secrets Operator](https://external-secrets.io/) (ESO) で AWS Secrets Manager / SSM Parameter Store 等の外部秘密情報を K8s Secret として注入する。

## なぜ ESO か

- `tailscale/base/secret.yaml` の OAuth credential 問題の構造的解決
- IRSA (IAM Roles for Service Accounts) で IAM ロール経由の認証
- ClusterSecretStore / SecretStore CRD で秘密情報のソースを宣言的に管理
- EKS Hybrid Nodes に Pi が join した後、Pi 上の Pod も IRSA 経由で AWS Secrets Manager を直接読める

## Layout

```
base/
  namespace.yaml
  values.yaml                Helm chart values
  clusterstore-aws.yaml      ClusterSecretStore (AWS Secrets Manager)
  kustomization.yaml         Helm chart + ClusterSecretStore
overlays/
  rasp/                      arm64 nodeSelector
  local/
```

## SyncWave

- wave=15 (golem co2 を踏襲、postgres-operator=10 の後、cert-manager=20 の前)

## IRSA セットアップ (EKS Hybrid Nodes 検証時)

1. AWS IAM Role を作成し SecretsManager 読取権限を付与
2. EKS の OIDC provider を信頼関係に追加
3. `base/values.yaml` の `serviceAccount.annotations.eks.amazonaws.com/role-arn` を有効化
4. 該当 ServiceAccount を Pod が assume → ClusterSecretStore 経由で Secret を取得

## ExternalSecret 利用例 (tailscale)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tailscale-auth
  namespace: tailscale
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: tailscale-auth
    creationPolicy: Owner
  data:
    - secretKey: clientId
      remoteRef:
        key: /k8s-deploy/tailscale/oauth
        property: clientId
    - secretKey: clientSecret
      remoteRef:
        key: /k8s-deploy/tailscale/oauth
        property: clientSecret
```

## 参考

- 公式: https://external-secrets.io/
- golem co2: `~/work/golem/gorlem-infra-main/co2/eks/external-secrets/base/secretstore.yaml`

---

## 2026-09-18: rpi0-hybrid で実運用に入れた

**背景**: ノードモジュールを足すたびに `terraform.tfvars` へ k3s token と Tailscale auth key を
複製していた(ec2 / gcp / azure / oci で同じ値が 4 か所)。更新漏れと置き忘れの温床なので、
**AWS Secrets Manager を単一の真実**にして、Terraform もクラスタも同じ 1 か所を読む形に変えた。

```
AWS Secrets Manager  example-env/rpi0-hybrid/
    ├── k3s-node-token
    └── tailscale-authkey
         │
         ├── Terraform  ec2/k3s-cilium-lakehouse-node/secrets.tf の data source
         └── クラスタ   ESO の ClusterSecretStore aws-secrets-manager → ExternalSecret
```

投入は `tools/put-cluster-secrets.sh`(値は画面にもシェル履歴にも出さない)。

### 変更点

- chart **0.10.5 → 2.10.0**。API が `external-secrets.io/v1beta1` → **`v1`** に変わっている
  (chart 2.x では v1 が保存バージョンで、v1beta1 は `crds.unsafeServeV1Beta1` を立てないと提供されない)
- 認証は **keyless**。SA annotation `eks.amazonaws.com/role-arn` を付け、
  ClusterSecretStore には **`auth` を書かない**。ESO は auth 未指定だとコントローラ自身の
  AWS 資格情報(= pod-identity-webhook が注入した web identity)を使う
- ロールは `AppCloudRole`(kro RGD)で合成。読めるのは `example-env/rpi0-hybrid/` 配下だけ
- overlays/rasp の arm64 固定パッチを削除。ハイブリッドクラスタでは amd64 ノードの方が余裕がある
- ApplicationSet `platform-hybrid` に wave 20 で登録(kro-rgds=15 の後)
