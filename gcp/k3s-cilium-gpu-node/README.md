# k3s-cilium-gpu-node — GCP L4 スポット GPU を rp0 クラスタの outpost にする

`k3s-cilium-hybrid-node`(CPU 版)の GPU 変種。**g2-standard-16(NVIDIA L4 24GB 内蔵)の
Spot VM** を Tailscale 純オーバーレイで rp0 クラスタに join させる。動画生成(ComfyUI + H3 等)の
実行基盤で、MIG + Cluster Autoscaler の 0↔1 でアイドル時ゼロ円にする。

## CPU 版との差分

| 項目 | CPU 版 | 本モジュール |
|---|---|---|
| machine_type | e2-medium | **g2-standard-16**(16vCPU/64GB/L4x1。G2 は L4 組み込みで accelerator 指定不要) |
| ディスク | 10GB pd-standard | **80GB pd-balanced**(`disk_size_gb` で変更可) |
| scheduling | SPOT | SPOT + **on_host_maintenance=TERMINATE**(GPU は live migration 不可のため必須) |
| startup | tailscale→k3s | **NVIDIA ドライバ(ubuntu-drivers --gpgpu)→container toolkit→**tailscale→k3s。初回のみ 1 回 reboot |
| node label | cloud=gcp, role=gcp-spot | cloud=gcp, **role=gpu-spot, gpu=l4** |
| taint | dedicated=gcp-ops | **dedicated=gpu-ops**:NoSchedule |
| subnet | 10.201.0.0/24 | 10.202.0.0/24(別 VPC。CPU 版と独立) |

k3s は agent 起動時に `nvidia-container-runtime` を検出すると containerd に nvidia runtime を
自動登録する([k3s docs: Advanced Options — NVIDIA Container Runtime](https://docs.k3s.io/advanced#nvidia-container-runtime-support))。
そのため **toolkit のインストールは k3s より先**(startup script がその順序になっている)。

## クラスタ側の前提(k8s-deploy main)

- `nvidia-device-plugin/`(RuntimeClass `nvidia` + device plugin DaemonSet, nodeSelector `gpu=l4`)が
  ArgoCD platform-hybrid で配布されること
- GPU Pod 側の契約: `runtimeClassName: nvidia` + `resources.limits."nvidia.com/gpu": 1` +
  `nodeSelector {gpu: l4}` + `tolerations [dedicated=gpu-ops:NoSchedule]`

## 使い方

```bash
cd gcp/k3s-cilium-gpu-node
cp terraform.tfvars.example terraform.tfvars   # secrets(k3s_token / tailscale_authkey)を記入
AWS_PROFILE=example-env terraform init && AWS_PROFILE=example-env terraform apply
```

- 検証時は `target_size=1`、運用は `0`(CA が pending Pod で起こす)
- **CA 側の登録**(0→1 を CA に任せる場合): cluster-ops の CA-gcp(helm CLI 管理、
  image=ghcr.io/shinichitazawa/cluster-autoscaler-gce-mixedfix)の起動 flag に
  `--nodes=0:1:https://www.googleapis.com/compute/v1/projects/example-project/zones/asia-northeast1-a/instanceGroups/gcp-gpu-mig`
  を 1 行追加する(既存 `gcp-cil-mig` の行と並べる)
- **scale-from-0 の GPU 認識**: GCE provider は MIG の instance template から GPU を推定するため
  node-template タグは不要(CPU 版の label/taint 広告と同じ注意: label/taint を変えたら startup の
  `--node-label`/`--node-taint` と一致させる)

## Phase 1 の素 VM を後から編入する

素の GPU VM(k8s なし・ドライバ導入済み)で品質検証してから編入する場合は、VM 上で:

```bash
sudo TS_AUTHKEY='tskey-auth-...' K3S_TOKEN='K10...' bash scripts/join-existing-gpu-vm.sh
```

MIG 管理外なので CA の増減対象にはならない(検証が終わったら VM ごと削除し、以後は MIG 経由で運用)。

## 費用目安(2026-08 時点、asia-northeast1 spot)

- g2-standard-16 spot: おおよそ ¥55〜70/時(スポット価格は変動。請求実測で確認)
- pd-balanced 80GB: ~¥5/日(VM を消しても MIG template には残らない。ノード削除で消える)
- **target_size=0 なら VM 課金ゼロ**(残るのは state/ネットワーク定義のみ)

## 関連

- CPU 版: `../k3s-cilium-hybrid-node/`(NAT/private 化の toggle も同じ変数体系)
- inbound 遮断の考え方: skill `hybrid-node-netsec`(GCP は ingress firewall を作らない=implied deny)
