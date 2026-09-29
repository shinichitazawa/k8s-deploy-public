# k3s-cilium-gpu-node (EC2) — AWS g6 スポット L4 を rp0 クラスタの outpost にする

`ec2/k3s-cilium-hybrid-node`(CPU 版)の GPU 変種。**g6.2xlarge(NVIDIA L4 24GB / 8vCPU / RAM 32GB)
の Spot ASG** を Tailscale 純オーバーレイで rp0 クラスタに join させる。
GCP 版 `gcp/k3s-cilium-gpu-node` の AWS 版フォールバック(GCP は GPUS_ALL_REGIONS クォータ待ち)。

## CPU 版との差分

| 項目 | CPU 版 | 本モジュール |
|---|---|---|
| instance_types | t4g 系 arm64 | **g6.2xlarge / g6.4xlarge**(x86_64、L4 24GB) |
| AMI | Ubuntu 24.04 arm64 | Ubuntu 24.04 **amd64** |
| ルート EBS | AMI 既定(8GB) | **80GB gp3**(`disk_size_gb`) |
| user-data | tailscale→k3s | **NVIDIA ドライバ→container toolkit→**tailscale→k3s |
| node label | cloud=aws, role=ec2-spot | cloud=aws, **role=gpu-spot, gpu=l4** |
| taint | dedicated=aws-ops | **dedicated=gpu-ops**:NoSchedule |
| ASG タグ | Name のみ | **CA auto-discovery + scale-from-0 の node-template タグ**(GPU/label/taint) |
| min/desired | 1/1 | **0/0**(ゼロスケール既定) |

- **EC2 の user-data は初回起動のみ実行**(GCP の毎ブート実行と違う)。そのため reboot 前提の
  2 段構えは使えず、`modprobe -r nouveau; modprobe nvidia` で reboot なしロードする。
  まれに失敗した場合はインスタンスを一度 reboot(device plugin は FAIL_ON_INIT_ERROR=true で再試行)。
- toolkit は **必ず k3s より先**(k3s が agent 起動時に nvidia runtime を containerd に自動登録)。

## クラスタ側の前提(共通・設定不要)

GCP GPU ノードと**ラベル/taint 契約が同一**(`gpu=l4` / `dedicated=gpu-ops`)なので、
`nvidia-device-plugin`(ArgoCD 配布済み)と Kro `GpuWorkload`(kro-rgds)が**そのまま効く**。

## 使い方

```bash
cd ec2/k3s-cilium-gpu-node
cp terraform.tfvars.example terraform.tfvars   # secrets(k3s_token / tailscale_authkey)を記入
AWS_PROFILE=example-env terraform init && AWS_PROFILE=example-env terraform apply
```

- **クォータ**: G/VT Spot の vCPU 枠(Service Quotas `All G and VT Spot Instance Requests`,
  L-3819A6DF)が必要(g6.2xlarge=8vCPU)。既定 0 の場合は引き上げ申請(利用実績のある
  アカウントは自動承認されやすい)。
- **CA 0↔1**: ASG に auto-discovery タグ(`k8s.io/cluster-autoscaler/enabled` /
  `.../rpi0-hybrid`)を付与済みなので、CA-aws(`--node-group-auto-discovery`)が自動検出する。
  scale-from-0 の GPU 認識は node-template タグ
  (`.../node-template/resources/nvidia.com/gpu=1` ほか label/taint)で広告。
  **label/taint を変えたら user-data と node-template タグの両方を必ず一致させる。**

## 費用目安(2026-08 時点、ap-northeast-1)

- g6.2xlarge Spot: 概ね $0.35〜0.5/時(変動。`aws ec2 describe-spot-price-history` で実測)
- gp3 80GB: ~$8/月相当(時間割ではわずか)。ASG 0 台なら EBS も存在しない
- **min=0 なら VM 課金ゼロ**

## 関連

- CPU 版: `../k3s-cilium-hybrid-node/`
- GCP 版: `../../gcp/k3s-cilium-gpu-node/`(構成対比は各 README)
- GPU 調達の比較(さくら高火力 DOK 含む): k8s-deploy main の `docs/gpu-options.md`
