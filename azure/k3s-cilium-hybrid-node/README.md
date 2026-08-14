# k3s + Cilium hybrid node (Azure) — Terraform

rpi0(k3s + Cilium kpr, CP)に、**Azure の VMSS ノード**を Tailscale 純オーバーレイで worker として join する Terraform モジュール。AWS/GCP/OCI と同格（autoscaling + keyless）。

## 設計

- **VMSS（Virtual Machine Scale Set）+ Spot**（AWS ASG / GCP MIG / OCI Instance Pool 相当）。`instances` を **0** でゼロスケール（CA/手動で 0↔N、`ignore_changes=[instances]`）。
- **最小/最安**: `Standard_B1s`(x86, burstable)。Spot(`priority=Spot`, `max_bid_price=-1`)。
- **keyless = System-assigned Managed Identity**（AWS instance profile 相当）: VMSS に付与された Managed Identity を、pod が IMDS(169.254.169.254) 経由で利用。Kro `AzureWorkload`(hostNetwork)。
- **共通 join 規約**: Tailscale 参加 / `--node-ip=<TSIP>` / label `cloud=azure` / taint `dedicated=azure-ops` / CP は MagicDNS FQDN。
- 自己完結: Resource Group + VNet + Subnet も本モジュールが作成。egress 用に per-instance public IP。

## 前提

- rpi0 が tailnet 参加・node-ip=TSIP・tls-san に FQDN・Cilium `KUBERNETES_SERVICE_HOST`=rpi0 TS IP
- Azure: サブスクリプション・`az login`（または `ARM_*` env）
- Managed Identity への RBAC ロール割当（ワークロードが触る Azure リソースに応じて。最小権限で）

## secrets

`.gitignore` 済み（`*.tfvars`）。

- `k3s_token`: rpi0 で `sudo cat /var/lib/rancher/k3s/server/node-token`
- `tailscale_authkey`: 管理コンソール（reusable+ephemeral）。同一 tailnet の既存キー流用可
- `ssh_public_key`: Azure Linux VM は鍵必須（運用は Tailscale SSH）

## 実行

```bash
cd azure/k3s-cilium-hybrid-node
cp terraform.tfvars.example terraform.tfvars   # subscription/ssh_public_key/secrets を記入
AWS_PROFILE=st-dev terraform init
AWS_PROFILE=st-dev terraform plan
AWS_PROFILE=st-dev terraform apply
```

## 検証

```bash
sudo k3s kubectl get nodes -l cloud=azure -o wide     # Ready
# AzureWorkload を投入 → azure node に hostNetwork で載り Managed Identity で Azure 操作
```

## ゼロスケール

`instances=0` で 0 台・課金 0。`cluster-autoscaler --cloud-provider=azure`（VMSS 対応）で pending の `cloud=azure` pod により自動起動。

**scale-from-0 用 node-template タグ**は本モジュールが VMSS に付与する（`locals.ca_node_template_tags`）。0 台のとき CA は「増設される node の label/taint」を VMSS タグから読むため。Azure はタグ名に `/` 不可なので `_` 置換（`k8s.io_cluster-autoscaler_node-template_label_cloud=azure` 等）。値は startup-script の `--node-label`/`--node-taint` と一致必須。以前は live に手動付与していたが codify 済み（drift 解消）。ref: [CA Azure provider](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider/azure)。

## 補足: オンプレ用途なら Azure Arc も

本モジュールは Azure の VM(VMSS)を追加する構成。もし「オンプレ Pi 自体を Azure 認証させたい」なら **Azure Arc-enabled servers**（Pi をオンボード→ローカル IMDS で Managed Identity）が別解。VM を立てない分ローカル完結。→ 用途で使い分け。

## 破棄

```bash
AWS_PROFILE=st-dev terraform destroy
sudo k3s kubectl delete node <node_name>
```

## クラウド対応表

| 項目 | AWS | GCP | OCI | Azure(本) |
|---|---|---|---|---|
| ノード供給 | ASG | MIG | Instance Pool | **VMSS** |
| ゼロスケール | min=0 | target=0 | size=0 | **instances=0** |
| keyless | IAM(IMDS) | SA(metadata) | Instance Principals | **Managed Identity(IMDS)** |
