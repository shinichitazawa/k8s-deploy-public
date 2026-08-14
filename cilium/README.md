# cilium

[Cilium](https://cilium.io/) eBPF-based CNI。

## なぜここにあるか

EKS Hybrid Nodes 移行時の必須 CNI (VPC CNI が使えない)。詳細は `../docs/eks-hybrid-nodes/05-cni-cilium.md` および `../docs/learning-notes/2026-05-cilium-ebpf-deep-dive.md`。

現在は rpi0(k3s CP) + マルチクラウド outpost(AWS/GCP/OCI/…) を Tailscale 純オーバーレイで束ねた
**ハイブリッド構成**で稼働している。その helm 値は `overlays/hybrid/values.yaml`。

## Layout

```
base/
  namespace.yaml
  values.yaml             kustomize 用 base helm 値 (chart 1.17.0 vendored、将来の EKS Hybrid 用)
  kustomization.yaml      Helm chart v1.17.0 取得
overlays/
  rasp/                   base 参照のみ (k3s と競合するため未投入)
  hybrid/
    values.yaml          ★ 稼働中 hybrid cilium の helm override 値 (k8sServiceHost=Tailscale IP)
policies/
  multicloud-zero-trust.yaml   CiliumNetworkPolicy (cloud-workloads ns 向け default-deny)
```

## 稼働実体と投入方法 (重要)

稼働中の cilium は **kustomize ではなく cilium CLI で install** されている。

- cilium-cli: v0.19.4 / chart(image): **v1.19.3**
- 値は helm release `cilium` に格納 (`kubectl -n kube-system get secret sh.helm.release.v1.cilium.*`)

投入・更新は必ず**バージョンを pin** して行う (cilium-cli の既定 image は新しい版に追随するため、
無指定 upgrade は意図せぬメジャー更新になる):

```bash
# 稼働値を維持したまま k8sServiceHost だけ直す(推奨・最小差分)
cilium upgrade --version 1.19.3 --reuse-values \
  --set k8sServiceHost=100.64.0.10 --set k8sServicePort=6443

# もしくは overlays/hybrid/values.yaml を丸ごと適用
cilium upgrade --version 1.19.3 -f cilium/overlays/hybrid/values.yaml
```

## 事後分析: k8sServiceHost 巻き戻りで cloud ノード全滅 (2026-07-19)

### 症状
AWS/GCP/OCI の全 outpost ノードが同時に `NotReady`。cilium pod が `Init:CrashLoopBackOff`。
rpi0(CP) のみ健全。

### 原因
cilium helm values の **`k8sServiceHost` が `192.0.2.17`(自宅 LAN IP)** になっていた。

```
cloud ノードは Tailscale オーバーレイ経由でしかクラスタに繋がらない
  → LAN IP 192.0.2.17 に到達不能
  → cilium config init が kube-apiserver に繋げず CrashLoop
  → CNI が張れず ノード NotReady (rpi0 は LAN 上なので無事 = 非対称)
```

### なぜ巻き戻ったか (根本)
ハイブリッド構築時、正しい Tailscale IP は `kubectl set env ds/cilium ...` の**手動 patch**で
当てていた。helm values(=正典)には焼いていなかった。`cilium upgrade`(helm upgrade v1→v2)が
走った際に ds が helm values から再レンダリングされ、**手動 patch が消えて LAN IP に戻った**。

宣言的管理下のリソースへの out-of-band 手動変更は次の同期で必ず消える、という典型例。

### 恒久対策 (このコミット)
`overlays/hybrid/values.yaml` に `k8sServiceHost: 100.64.0.10`(rpi0 Tailscale IP)を焼き込み、
live helm release にも `cilium upgrade --reuse-values --set k8sServiceHost=...` で反映。
以後 upgrade しても TSIP を維持する。手順は `.claude/skills/cilium-hybrid`。

## 注意

- `base/` の chart は 1.17.0 vendored だが**稼働は 1.19.3**。base は将来の EKS Hybrid 用の雛形。
- 現状の Pi(k3s) で `kubectl apply -k cilium/overlays/rasp` すると Flannel と衝突する。

## 参考

- 公式 helm chart: https://github.com/cilium/charts
- k8sServiceHost/Port (kube-proxy-free): https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- `../docs/eks-hybrid-nodes/05-cni-cilium.md` — カーネル動作
