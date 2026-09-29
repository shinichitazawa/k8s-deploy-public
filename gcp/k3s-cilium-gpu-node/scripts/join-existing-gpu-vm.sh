#!/bin/bash
# Phase 1 で作った素の GPU VM(ドライバ導入済み)を、後から rp0 クラスタに編入するスクリプト。
# VM 上で root として実行する。秘匿値は環境変数で渡す(引数やファイルに残さない):
#
#   sudo TS_AUTHKEY='tskey-auth-...' K3S_TOKEN='K10...' bash join-existing-gpu-vm.sh
#
# 前提: nvidia-smi が動くこと(Phase 1 の bootstrap でドライバ導入済み)。
set -euo pipefail
: "${TS_AUTHKEY:?TS_AUTHKEY (tskey-auth-...) を環境変数で渡してください}"
: "${K3S_TOKEN:?K3S_TOKEN (rp0 の node-token) を環境変数で渡してください}"
K3S_CP_HOST="${K3S_CP_HOST:-raspberrypi-0.example.ts.net}"
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"
NODE_NAME="${NODE_NAME:-gcp-gpu-$(hostname -s)}"

export DEBIAN_FRONTEND=noninteractive
nvidia-smi >/dev/null || { echo "ERROR: nvidia-smi が動きません。先にドライバを入れてください"; exit 1; }

# NVIDIA Container Toolkit(k3s インストールより前に。k3s が containerd に nvidia runtime を自動登録する)
if ! command -v nvidia-container-runtime >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y && apt-get install -y nvidia-container-toolkit
fi

# Tailscale 参加
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --accept-dns=true --ssh --hostname="$NODE_NAME" --authkey="$TS_AUTHKEY"
TSIP=""
for i in $(seq 1 20); do TSIP=$(tailscale ip -4 2>/dev/null | head -1); [ -n "$TSIP" ] && break; sleep 2; done
[ -n "$TSIP" ] || { echo "ERROR: tailscale IP が取れません"; exit 1; }

# providerID(GCE メタデータから。スタンドアロン VM は CA 管理外だが形式は揃えておく)
MD="http://metadata.google.internal/computeMetadata/v1"
ZONE=$(curl -s -H "Metadata-Flavor: Google" $MD/instance/zone | awk -F/ '{print $NF}')
INAME=$(curl -s -H "Metadata-Flavor: Google" $MD/instance/name)
PROJECT=$(curl -s -H "Metadata-Flavor: Google" $MD/project/project-id)

# k3s agent join(cloud=gcp / role=gpu-spot / gpu=l4 + dedicated=gpu-ops taint)
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  K3S_URL="https://$K3S_CP_HOST:6443" \
  K3S_TOKEN="$K3S_TOKEN" \
  INSTALL_K3S_EXEC="agent --node-name=$NODE_NAME --node-label=cloud=gcp --node-label=role=gpu-spot --node-label=gpu=l4 --node-ip=$TSIP --kubelet-arg=provider-id=gce://$PROJECT/$ZONE/$INAME --node-taint dedicated=gpu-ops:NoSchedule" sh -

echo "join 完了: $NODE_NAME ($TSIP)。確認: kubectl get node $NODE_NAME; kubectl describe node $NODE_NAME | grep nvidia.com/gpu"
