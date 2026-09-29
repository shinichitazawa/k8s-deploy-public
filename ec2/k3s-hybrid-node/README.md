# k3s hybrid node (EC2) — Terraform / Terrakube

> **⚠️ 注記（2026-07 時点・依存の前提が変化）**: 本モジュールが依存していた
> **`rpi2-subnet-router`（192.0.2.0/24 を広告）は廃止済み**（セキュリティ上、自宅 LAN 全体を
> tailnet へ橋渡しするのを止めたため）。現状のままでは EC2 が CP(`192.0.2.8`)に到達できず join できない。
> going-forward は **純オーバーレイ（全ノードを tailnet 参加させ、CP も TS IP / MagicDNS で到達）** へ移行する。
> 実装例は Cilium 版 [`../k3s-cilium-hybrid-node`](../k3s-cilium-hybrid-node) を参照（subnet route を使わない設計）。

自宅 LAN の Raspberry Pi k3s クラスタ（flannel）に、AWS の EC2 を **Tailscale subnet route 経由**で worker node として join する Terraform モジュール。Terrakube から実行できる。

## 何を作るか

- `aws_security_group` (SSH は指定 CIDR のみ、egress 全許可)
- `aws_instance` (既定 **t4g.small / arm64 / Spot / Ubuntu 24.04**)
- `user_data` が起動時に **Tailscale 参加 → subnet route(192.0.2.0/24) 受領 → k3s agent join** を自動実行

前提（このモジュール外・一度きり）:
- LAN 上の 1 台（例: `rpi2`）が Tailscale **subnet router** として `192.0.2.0/24` を広告し、Tailscale 管理コンソールで **route 承認済み**であること。
- EC2 は CP の LAN IP `192.0.2.8:6443` に繋ぐ（この IP は k3s が自動で証明書 SAN に入れているため、SAN 追加のための k3s 再起動は不要）。

## secrets

`k3s_token` と `tailscale_authkey` は **sensitive 変数**。リポジトリにコミットしない（`.gitignore` で `*.tfvars` 除外済み）。

- k3s_token: CP で `sudo cat /var/lib/rancher/k3s/server/node-token`
- tailscale_authkey: Tailscale 管理コンソール → Settings → Keys → Generate（Reusable 推奨）

## Terrakube での実行

1. Terrakube に本リポジトリを VCS 連携し、Working Directory を `ec2/k3s-hybrid-node` に設定。
2. Terrakube の **Variables** に非機密値（region 等）、**Sensitive Variables** に `k3s_token` / `tailscale_authkey` を登録。
3. Plan → Apply。state は Terrakube の backend か、`backend.tf` の S3 (`example-terraform-state`) を使用。

## ローカル(CLI)での実行

```bash
cd ec2/k3s-hybrid-node
cp terraform.tfvars.example terraform.tfvars   # secrets を追記
terraform init
terraform plan
terraform apply
```

## 既存(imperative 作成)リソースの取り込み（作り直さず管理下に）

手動 aws-cli で作成済みの SG / Spot インスタンスを、破棄せず本モジュールの管理下に import する:

```bash
terraform import aws_security_group.node <SG_ID>      # 例: sg-00f36e35fe69979fa
terraform import aws_instance.node       <INSTANCE_ID> # 例: i-052eafdb0d68f832c
terraform plan   # user_data/ami は ignore_changes 済み。差分が無いことを確認
```

## なぜ Terraform (Terrakube) で、Kro ではないか

- EC2 / SG / Spot は AWS リソースであり **Terraform の本領**。Terrakube はその Terraform ランナー。
- **Kro（＋ACK）は k8s ネイティブなリソース合成**が本領。EC2 を Kro で作るには ACK EC2 controller が必要で、かつ「クラスタが自分の worker を生やす」循環＋k3s に IRSA が無く静的クレデンシャルが要り、この用途には過剰。
- 役割分担: **ノード(インフラ)= Terraform/Terrakube**、**クラスタ内 k8s リソース = Kro**。join 後にこの EC2 ノード上へ載せるアプリを Kro の RGD で宣言的に組む、という組み合わせが素直。

## 破棄

```bash
terraform destroy
# k3s 側のノード掃除:
kubectl --context raspberry delete node <node_name>
```
