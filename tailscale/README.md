# tailscale

[https://tailscale.com/]

```bash

curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

``

# wireguard

[https://www.wireguard.com/install/]

```bash

sudo apt install wireguardsudo apt install wireguard

```

# operator

privateのk8s-apiにアクセスするためのoperator

## install

```bash

tailscale configure kubeconfig tailscale-operator

```

