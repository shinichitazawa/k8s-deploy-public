# cluster-autoscaler sakuracloud provider (フォーク実装)

upstream に存在しないさくらのクラウド用 cloudprovider を、CA の実装規約
(Hetzner 型)に則ってフォークに追加したもの。さくらには ASG/MIG 相当が
無いため、**CA 自身が server+disk を create/delete** する。

- `sakuracloud/` — provider 本体(フォークの
  `cluster-autoscaler/cloudprovider/sakuracloud/` にそのまま置く)
- `registration.patch` — provider 名定数と builder 登録
  (`cloud_provider.go` / `builder/builder_all.go`)
- `Dockerfile` — ビルド用(gce mixedfix と共通)
- `startup-note.sh.example` — join 用スタートアップスクリプトの雛形
  (実物は secrets を埋めて さくらの note として作成)

## ビルド

```sh
git clone --depth 1 --branch cluster-autoscaler-1.35.0 \
  https://github.com/kubernetes/autoscaler
cd autoscaler
git apply .../ca-gce-mixedfix/nodegroupfornode-unmanaged.patch   # 同梱推奨
git apply .../ca-sakuracloud-provider/registration.patch
cp -r .../ca-sakuracloud-provider/sakuracloud cluster-autoscaler/cloudprovider/
docker buildx build --platform linux/arm64 -f Dockerfile \
  -t ghcr.io/shinichitazawa/cluster-autoscaler-sakuracloud:v1.35.0 --push .
```

イメージは ghcr **private**。pull は cluster-ops の `ghcr-pull` を使用。

## セットアップ(検証手順)

1. さくらの API キー → Secret `cluster-ops/sakuracloud-api`
   (`SAKURACLOUD_ACCESS_TOKEN` / `SAKURACLOUD_ACCESS_TOKEN_SECRET`)
2. startup note 作成(`startup-note.sh.example` に secrets を埋めて
   `usacloud note create`)→ note ID を控える
3. Ubuntu 24.04 の source archive ID を確認
   (`usacloud archive list --zone tk1b`)
4. `cluster-config.yaml` の REPLACE_* を実 ID に置換して apply
5. `deployment.yaml` を apply(../ca-sakura/)

## 設計メモ

- providerID: `sakuracloud://<zone>/<serverName>`。kubelet 側は startup note の
  `--kubelet-arg=provider-id`(hostname=server 名から導出)。
- グループ帰属: server の `ca-group-<groupName>` タグ。
- `NodeGroupForNode` は非 sakuracloud:// providerID に nil を返す
  (GCE provider の混在 providerID fatal と同じ轍を踏まない)。
- scale-from-0: `TemplateNodeInfo` が config の labels/taints を広告。
- 供給フロー: disk 作成(archive コピー、~数分) → server 作成(共有セグメント)
  → disk attach → disk config(hostname+note) → 電源 ON。goroutine で非同期。
- 削除: 強制停止 → disk ごと削除。

## 既知の制約 / さくら API の癖(実測)

1. server plan は ID 指定だと 400 → `{"CPU":n,"MemoryMB":m}` の spec 指定が正。
2. `PUT /disk/:id/config` 直後は disk が変更中 → 即電源 ON は 409。再度 available 待ち。
3. サーバ一覧レスポンスに電源状態が無い → 削除は常に強制停止を先行し、既に停止の 409 は無視。
4. provisioning が途中段階(電源 ON など)で失敗した場合、server/disk が残ることがある。
   `ca-group-*` タグ / `sakura-cil-*` 名で棚卸しして手動削除する。

## ネットワーク / セキュリティ設定（node group ごと）

`cluster-config` の node group に追加できるフィールド:

```json
{
  "network": "shared",     // 既定。共有セグメント接続=グローバル(public)IP 付与
  "switchID": "",          // network="switch" のとき必須。ユーザースイッチ(private)に接続
  "blockInbound": true     // shared のとき既定 true。inbound 遮断のパケットフィルタを自動 attach
}
```

- **A: パケットフィルタ（`blockInbound`）** — さくらのパケットフィルタは
  [stateless・inbound のみ](https://manual.sakura.ad.jp/cloud/network/packet-filter.html)
  のため、戻り許可（ephemeral 32768-61000）＋ Tailscale WireGuard(UDP 41641)＋ICMP を
  allow、その他 inbound を deny する `ca-inbound-<group>` フィルタを作成し NIC に付与する。
  これで public IP でも **ssh(22)/kubelet(10250) など外からの inbound は全遮断**され、
  到達は Tailscale 経由のみになる。
- **B: private スイッチ（`network:"switch"`＋`switchID`）** — public IP なしにする場合。
  ただしスイッチ側に **VPC ルータ等の egress(NAT+DHCP)** が別途必要（ノードは起動時に
  Tailscale/イメージ取得で outbound する）。static IP 割当(IP プール)は未実装。

適用にはイメージ再ビルド＋再デプロイが必要（下記ビルド手順）。
