# kro

[Kube Resource Orchestrator](https://github.com/kubernetes-sigs/kro) (Kro) v0.8.5 の導入。

## なぜ Kro か

Kustomize は個別リソースの patch 管理に強いが、複合リソース (Deployment + Service + ConfigMap + IAM Role など) を 1 つの spec から生成する抽象化は不得意。Kro の `ResourceGraphDefinition` (RGD) はこれを K8s ネイティブ API で表現する上位層を提供する。

```
[低レベル]  Kustomize (個別リソース、base/overlays)         ← 既存
[中レベル]  ArgoCD ApplicationSet (matrix で展開)            ← 既存
[上レベル]  Kro RGD (複合リソースを 1 つの spec で記述)        ← NEW
```

## Layout

```
base/
  namespace.yaml                  ns: kro
  values.yaml                     Helm chart values
  kustomization.yaml              Helm chart + RGD
  rgd-simple-webapp.yaml          ResourceGraphDefinition (PoC)
overlays/
  rasp/
    kustomization.yaml
    deployment-patch.yaml         arm64 nodeSelector / tolerations
    instance-example.yaml         RGD instance "hello-rasp" (PoC)
  local/
    kustomization.yaml
```

## SyncWave

- wave=3: Kro controller install
- wave=4: RGD 定義 (`simple-webapp`)
- wave=14: instance (`hello-rasp`)

## 適用

```bash
kubectl apply -k kro/overlays/rasp
kubectl get crd | grep kro.run
kubectl -n kro get resourcegraphdefinition
kubectl -n kro get simplewebapp
```

## アプリのクラウド権限(S3/IAM)= Kro + ACK

アプリが必要とする **S3 バケット + 最小権限 IAM** を、開発者が高レベル CR 1枚
(`kind: AppCloudAccess`)で宣言できるようにする RGD を用意した(`base/rgd-app-cloud-access.yaml`)。
中で **ACK(AWS Controllers for Kubernetes)** の `Bucket` / `Policy` / `Role` を合成する。
狙いは「手作業 IAM / Terraform 分散をやめ、アプリと権限を同じ GitOps 宣言で一元管理」。

宣言例:

```yaml
apiVersion: kro.run/v1alpha1
kind: AppCloudAccess
metadata:
  name: myapp-access
  namespace: infra          # 管理系は infra に集約(multi-k3s 方針)
spec:
  name: myapp
  bucketName: example-myapp-data
  access: readwrite
  trustPrincipalArn: ""     # keyless 方式決定後に埋める
```

### ★ ACK 有効化(前提。未導入のため base/kustomization には未組込)

1. **ACK controller 導入**: `ack-s3-controller` + `ack-iam-controller`(Helm)を **`cluster-ops` ns**
   (運用ツール集約先)へ。CRD `s3.services.k8s.aws/Bucket`, `iam.services.k8s.aws/{Role,Policy}` が生える。
   ※ アプリの Bucket/Role 資源自体は `infra`(アプリ共有基盤)側に置く(RGD の template ns 参照)。
2. **ACK の AWS 認証方式 = self-hosted OIDC(IRSA 相当) に決定**(2026-07)。
   rpi0 は cloud ID を持たないため、ServiceAccount トークンを OIDC で AWS に提示し
   `AssumeRoleWithWebIdentity` でロールを assume する(**keyless**、静的キーを排除)。issue #7 と統合。
   実装依存:
   - **公開 JWKS / OIDC discovery エンドポイント**が要る(k3s の SA issuer を公開 or 専用 OIDC provider)。
   - AWS 側に **IAM OIDC provider** を登録し、ACK controller/アプリの Role の
     `assumeRolePolicyDocument` を `Federated`(その provider ARN)+ `sub` 条件で絞る。
   - `rgd-app-cloud-access.yaml` の `trustPrincipalArn` は、この OIDC provider ARN を指す
     (単純な AWS principal でなく Federated trust に書き換える。RGD コメント参照)。
   - 却下: 静的キー Secret(非 keyless) / AWS ノード instance profile(ノード安定性に依存)。
3. controller が動いたら `base/kustomization.yaml` の resources に
   `rgd-app-cloud-access.yaml` を追加(sync-wave=6)し、instance を `infra` ns に置く。

※ `rgd-app-cloud-access.yaml` 内の ACK フィールド名(`spec.policyDocument`, `spec.policies` 等)は
CRD バージョン依存。導入時に `kubectl explain` で実 CRD に対して要検証(ファイル内コメント参照)。

## 参考

- 公式: https://github.com/kubernetes-sigs/kro
- ACK: https://aws-controllers-k8s.github.io/community/
- golem co2 の RGD パターン: `~/work/golem/gorlem-infra-main/co2/eks/applicationset-ack-kro.yaml`
