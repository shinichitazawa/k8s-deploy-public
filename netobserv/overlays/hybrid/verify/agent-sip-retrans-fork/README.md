# netobserv-ebpf-agent フォーク: 独自 eBPF フック 2 種

upstream(quay.io/netobserv/netobserv-ebpf-agent:main)に無い独自計測をフォークで追加。
どちらも既存 flow レコードに相乗りするため、FLP の Kubernetes enrichment
(Pod 名付与)がそのまま効く。

## 追加フック

1. **TCP 再送トラッキング**(`ENABLE_TCP_RETRANS`)
   - `tcp:tcp_retransmit_skb` tracepoint。flow_id は tracepoint 引数から構築
     (送信経路の skb は L2/L3 ヘッダ未構築のため skb 解析はしない)
   - flow フィールド: `TcpRetransPackets` / `TcpRetransBytes`
2. **SIP トラッカー**(`ENABLE_SIP_TRACKING`)
   - TC パスで port 5060(UDP/TCP)のペイロード先頭 12 バイトを解析し、
     メソッド(INVITE/REGISTER/ACK/BYE/CANCEL/OPTIONS)と応答コードを判定
   - flow フィールド: `SipMessages` / `SipRequests` / `SipResponses` /
     `SipLatestMethod` / `SipLatestRespCode`

## 変更ファイル(sip-retrans.patch + 新規 2 ファイル)

- bpf/: `tcp_retrans.h`(新規)・`sip_tracker.h`(新規)・types.h・
  maps_definition.h・configs.h・flows.c
- pkg/config/config.go(ENABLE_* 環境変数)、pkg/tracer/tracer.go(map サイズ・
  attach・flush・pin・RewriteConstants)、pkg/model/flow_content.go(Accumulate)、
  pkg/decode/decode_protobuf.go(FLP フィールド出力)
- pkg/ebpf/ は `make docker-generate` で再生成(パッチには生成差分も含む)

## ビルド

```sh
git clone https://github.com/netobserv/netobserv-ebpf-agent && cd netobserv-ebpf-agent
cp .../tcp_retrans.h .../sip_tracker.h bpf/
git apply .../sip-retrans.patch
make docker-generate       # bpf2go 再生成(要 docker)
docker buildx build --platform linux/arm64,linux/amd64 \
  -t ghcr.io/shinichitazawa/netobserv-ebpf-agent-custom:sip-retrans --push .
```

イメージは ghcr **private**。pull は netobserv ns に ghcr-pull secret が必要。

## 実装時の注意(実測)

- types.h の `unusedNN` 連番は後方の SSL/QUIC 定義と衝突しない番号にする
  (unused14/15 は使用済みで redefinition エラーになった)
- コンパイルは `GOFLAGS=-buildvcs=false` が必要(コンテナ内 git 情報なし)
