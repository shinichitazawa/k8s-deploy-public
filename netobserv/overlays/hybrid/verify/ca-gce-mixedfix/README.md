# cluster-autoscaler GCE provider mixed-providerID fix

GCE provider は `NodeGroupForNode` で全ノードの providerID を `gce://` として
parse し、他形式(`k3s://`, `azure://`, `aws://` など)に出会うとエラーを返す。
CloudProvider 契約では「自分の管理外ノードには nil を返す」のが正しく
(AWS/Azure 実装はそうしている)、このエラーが node-info 構築や
resource-quota 集計のループ全体を中断させ、混在 providerID クラスタでは
scale-up 不能になる(v1.32/1.34/1.35 で実測。エラー箇所が移動するだけ)。

## 再現手順

```sh
git clone --depth 1 --branch cluster-autoscaler-1.35.0 \
  https://github.com/kubernetes/autoscaler
cd autoscaler
git apply .../nodegroupfornode-unmanaged.patch
docker buildx build --platform linux/arm64 -f Dockerfile.mixedfix \
  -t ghcr.io/shinichitazawa/cluster-autoscaler-gce-mixedfix:v1.35.0 --push .
```

- 1.35 系は vendor 非同梱のため `-mod=vendor` は使えない(`go mod download` 方式)。
- イメージは ghcr **private**。pull には cluster-ops ns の `ghcr-pull`
  (dockerconfigjson) を imagePullSecrets に指定する。
- 適用先: `deploy/cluster-autoscaler-gcp-gce-cluster-autoscaler`
  (container 名は `gce-cluster-autoscaler`)。

## 確認済み(2026-08-14)

- 旧 v1.35 は 1 ループ以内に `could not create quotas tracker: failed to get
  node group for node "raspberrypi-0"` の fatal。
- パッチ版は `Node raspberrypi-0 has non-GCE providerID "k3s://raspberrypi-0",
  treating as unmanaged` とスキップし、メインループが安定して回る。
