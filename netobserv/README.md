# netobserv

[NetObserv eBPF Agent](https://github.com/netobserv/netobserv-ebpf-agent) を direct-flp モード (stdout 出力) で DaemonSet として deploy するための kustomize 構成。

## 目的

EKS Hybrid Nodes 検証準備の一環として、Cilium Hubble に依らないネットワーク観測選択肢を実環境 (Pi k3s) で動作確認する。

## Layout

```
base/
  namespace.yaml            ns: netobserv
  configmap.yaml            flp-config.json (stdout writer)
  daemonset.yaml            netobserv-ebpf-agent (privileged, hostNetwork, hostPID)
  kustomization.yaml
overlays/
  rasp/                     arm64 nodeSelector + master/control-plane toleration
  local/                    base 参照のみ
```

## 適用

```bash
kubectl apply -k netobserv/overlays/rasp
kubectl -n netobserv get pods -o wide
kubectl -n netobserv logs daemonset/netobserv-ebpf-agent --tail 50 -f
```

## フロー出力の見方

`EXPORT=direct-flp` + `flp-config.json` で stdout writer を設定しているため、Pod ログにフローが 1 行 1 イベントで出る:

```
map[AgentIP:... Bytes:... DstAddr:... DstPort:... Etype:2048 Packets:... Proto:6 SrcAddr:... SrcPort:... Interfaces:[eth0]]
```

## 公式情報

- [netobserv-ebpf-agent README](https://github.com/netobserv/netobserv-ebpf-agent)
- 動作要件: Linux kernel 5.8+ with eBPF enabled
- 必要 capability: `BPF` + `PERFMON` + `NET_ADMIN` または `privileged: true`
- サポートアーキ: amd64 / arm64 / ppc64le / s390x
