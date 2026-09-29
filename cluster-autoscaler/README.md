# cluster-autoscaler

Pending Pod を検知して cloud の node group(ASG/MIG/…)を **0→N に自動増減**する。
issue #13。Phase1 = **AWS**(ASG + keyless IRSA)。Phase2 = **GCP**(zonal MIG + keyless WIF) / **Azure**(VMSS + keyless Workload Identity)。**3 クラウドとも live 検証済み**。

## 位置づけ

```
イベント → [KEDA] Pod 0→N → Pod Pending → [Cluster Autoscaler] Node 0→N → Pod 起動
```

- **Karpenter は採用しない**(実質 AWS 専用・EKS 前提で、Tailscale overlay の多クラウド k3s に不適)。
- CA は多クラウド対応。**クラウド別に1つずつ**動かす(まず AWS)。

## 認証 = keyless(IRSA)

CA の AWS 権限は **self-hosted IRSA(#7 / skill k3s-irsa)** で付与。静的キー不使用。
SA `cluster-autoscaler` に `eks.amazonaws.com/role-arn` を付け、pod-identity-webhook が注入。

IAM ロール `cluster-autoscaler-role`(要作成):
- trust: Federated OIDC, `sub=system:serviceaccount:cluster-ops:cluster-autoscaler`
- 権限: `autoscaling:Describe*` / `ec2:Describe*`(Resource=*)+ `autoscaling:SetDesiredCapacity`
  `autoscaling:TerminateInstanceInAutoScalingGroup`(タグ `k8s.io/cluster-autoscaler/enabled=true` 条件)

## ★ 最重要の落とし穴: k3s ノードの providerID

**cloud-provider の無い自前 k3s では、ノードに AWS providerID が付かない**。すると CA は ASG の
インスタンスと k8s Node を対応付けられず機能しない。**cloud-init(user-data)の k3s agent に
providerID を付与**すること:

```bash
# ec2/k3s-cilium-hybrid-node の user-data 内、IMDS から取得して k3s agent に渡す
IID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
# k3s agent 起動オプションに追加:
#   --kubelet-arg=provider-id=aws:///${AZ}/${IID}
```

## ASG 側の前提(Terraform で codify すべき)

- ASG に auto-discovery タグ: `k8s.io/cluster-autoscaler/enabled=true`,
  `k8s.io/cluster-autoscaler/rpi0-hybrid=owned`。
- `min_size=0`(ゼロスケール維持)、`max_size>=1`(増設余地)。

## Layout

```
base/
  values-aws.yaml        cloudProvider=aws / ASG auto-discovery / IRSA SA(keyless) / scale-down  ← 検証済み
  values-gcp.yaml        cloudProvider=gce / zonal MIG(URL明示) / WIF credential-config(keyless)  ← 検証済み
  values-azure.yaml      cloudProvider=azure / VMSS / workload identity(keyless, 手動 token wiring)  ← 検証済み
  configmap-gcp.yaml     GCP CA 補助: WIF credential-config.json + gce.conf(project/zone)の ConfigMap
  rbac-gcp-lease.yaml    GCP CA の分離 lease(cluster-autoscaler-gcp)への Role/RoleBinding
  rbac-azure-lease.yaml  Azure CA の分離 lease(cluster-autoscaler-azure)への Role/RoleBinding
  kustomization.yaml     helm chart cluster-autoscaler 9.59.0。AWS/GCP/Azure すべて有効
overlays/rasp/           rpi0 ハイブリッド向け
```

CA は **1 プロバイダ=1 デプロイ**。クラウド別に helmChart(releaseName cluster-autoscaler-{aws,gcp,azure})。

## 投入

```bash
kubectl --context rpi0-hybrid apply -k cluster-autoscaler/overlays/rasp   # 単体
# 本筋は ArgoCD self-heal 配下(applications/platform-hybrid.yaml に追加)
```

## 検証(Phase1 完了条件)

1. AWS ノードを要求する Pending Pod を作る(`nodeSelector: {cloud: aws}` + toleration、ASG は desired=0)。
2. CA が ASG desired を上げる → 新インスタンスが cloud-init で k3s+Tailscale join(providerID 付き)。
3. Pod が載る。
4. Pod 削除 → idle 5分 → CA が ASG を 0 に戻す。

## 現状 / 残

**AWS(Phase1)**
- [x] CA app codify + デプロイ、**keyless(IRSA)で ASG 増設判断を実証**(Pending Pod → desired 0→1)
- [x] IAM ロール `cluster-autoscaler-role`(IRSA)作成
- [x] ASG discovery タグ + node-template ラベル、Terraform で instance_types 多様化 + **user-data に providerID + cloud=aws**(適用済み)、min_size=0 + ignore_changes[desired]
- [ ] **実ノード完走**: spot が断続的に `UnfulfillableCapacity`(quota=96・価格ありでも)→ CA backoff。
      確実化には on-demand fallback(コスト)or spot 容量待ち。設定は正しい。

**GCP(Phase2) — live 検証完了(2026-07)**
- [x] user-data に providerID(`gce://<project>/<zone>/<instance>`) + cloud=gcp。spot は既設。
- [x] **keyless(WIF)認証**: GSA `k3s-ca`(roles/compute.instanceAdmin.v1)+ WIF impersonation バインド
      (principal=…:cluster-autoscaler-gcp)+ external_account credential-config → ConfigMap `cluster-autoscaler-gcp-wif`。
      CA pod に projected token(aud=provider リソース名)+ `GOOGLE_APPLICATION_CREDENTIALS` を注入。
- [x] マルチ CA 共存: **lease 名を分離**(`--leader-elect-resource-name`)+ その lease への RBAC 補足(`ca-gcp-lease`)。
- [x] **metadata 依存を回避**: GCE CA は既定で GCP metadata(169.254.169.254)へ問い合わせ → rpi0(オンプレ)で
      timeout。`--cloud-config`(gce.conf: project-id + local-zone、ConfigMap `ca-gcp-cloudconfig`)で回避。
- [x] **MIG を zonal 化(元 blocker の解決)**: GCE CA の URL parser は zonal 形式
      (`.../zones/<zone>/instanceGroups/<n>`)しか受け付けず、regional(`.../regions/<r>/…`)を
      "wrong url" で拒否した。Terraform を `google_compute_region_instance_group_manager` →
      `google_compute_instance_group_manager`(zonal, `asia-northeast1-a`)に変更。
      **トレードオフ: spot 在庫が単一ゾーンに限定**(regional のクロスゾーン耐性は失う)。
- [x] **chart の落とし穴**: `extraArgs` の node-group-auto-discovery だけでは Deployment が描画されない
      (chart のガードが `autoscalingGroups`/`autoDiscovery.*` を要求)。`autoscalingGroups[].name` に
      **zonal MIG の instanceGroups URL** を渡す方式に変更(zonal URL を渡す経路も兼ねる)。
- [x] **`iamcredentials.googleapis.com` を有効化**: WIF impersonation の `generateAccessToken` が使う。
      未有効だと 403 SERVICE_DISABLED。
- [x] **検証結果**: CA が zonal MIG を Registering、MIG instances cache をクリーンに更新、
      scale-from-0 のノードテンプレート構築成功(benign warning のみ)、8h 0 restart。
      kustomization で GCP を有効化済み(AWS と 2 プロバイダ稼働)。
- [ ] 実ノード完走(0→1 spot 起動 + 専用 VPC での join)は未実施(コスト最小化で保留)。設定は完成。

**Azure(Phase2) — live 検証完了(2026-07)**
- [x] user-data(startup-script)に providerID(`azure:///…/virtualMachines/<instanceId>`)を IMDS から組立。
      cloud=azure label 既存。VMSS は Spot・capacity 0。
- [x] **keyless(Workload Identity)認証**: app `4c348c8c` に federated credential
      (subject=`system:serviceaccount:cluster-ops:cluster-autoscaler-azure`, aud=`api://AzureADTokenExchange`,
      issuer=自前 S3 OIDC)を追加。app SP に **VMSS スコープの Contributor** を付与。
- [x] **webhook 無しの手動 wiring**: azure-workload-identity webhook 未導入のため、projected token
      (aud=api://AzureADTokenExchange)+ `AZURE_CLIENT_ID/TENANT_ID/FEDERATED_TOKEN_FILE/AUTHORITY_HOST`
      を values で手動注入。chart は Secret(SubscriptionID/RG/VMType)+ `ARM_USE_WORKLOAD_IDENTITY_EXTENSION=true`。
- [x] マルチ CA 共存: **lease 名を分離**(`--leader-elect-resource-name=cluster-autoscaler-azure`)+ RBAC 補足(`ca-azure-lease`)。
- [x] **検証結果**: CA が VMSS を keyless で refresh(`Refreshed Azure VM and VMSS list`)、`azure-cil-vmss` を
      size 0 で登録、scale-from-0 のノードテンプレート構築成功(SKU `Standard_B2pts_v2`/japaneast)、
      認証エラー皆無・0 restart。kustomization で有効化済み(AWS/GCP/Azure の 3 プロバイダ稼働)。
- [ ] 実ノード完走(0→1 spot 起動 + join)は未実施(コスト最小化で保留)。設定は完成。
      補足: `Falling back to static SKU list` は SKU list 権限未付与時の benign fallback(scale-from-0 は静的 SKU で成立)。

## 参考

- [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler) / [AWS provider](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md)
- skill [[k3s-irsa]] / [[multi-k3s]] / issue #13, #7
