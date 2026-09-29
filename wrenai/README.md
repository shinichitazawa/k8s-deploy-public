# wrenai — レイクハウスの意味の層を配る MCP サーバ

[WrenAI](https://github.com/Canner/WrenAI) の `wren serve mcp` をクラスタ内で動かす。
AI エージェントはここに MCP で繋ぎ、MDL(モデル / ビュー / cube / ルール)を読んだうえで
Trino(`trino/`)に SQL を投げる。LLM はこの pod の中には無い。考えるのは繋いでくるエージェント側。

```
S3 → Iceberg → Lakekeeper(技術カタログ) → Trino → wren-mcp(意味の層) → エージェント
```

Lakekeeper が「表の実体がどこにあるか」を管理するのに対し、こちらは
「その列や集計が何を意味するか」を管理する。役割は重ならない。

## 構成

| | |
|---|---|
| wrenai | 0.15.0(2026-09-21 時点の PyPI 最新) |
| image | `python:3.14.7-slim-trixie` を**ダイジェスト固定**(2026-09-21 時点の 3.14 系最新) |
| 依存 | `base/requirements.lock`(65 パッケージ、**ハッシュ固定**、wheel のみ、x86_64) |
| 配置 | `lab-worker-14`(lock が x86_64 向けのため) |
| 接続先 | `trino.trino.svc.cluster.local:8080`、catalog `lakehouse`。秘密値は無い |
| 公開 | ClusterIP `wren-mcp.wrenai:8080` と Tailscale Ingress `https://wren-mcp.example.ts.net/mcp` |
| ArgoCD | app `wrenai`、wave 55(Trino=50 の後) |

### 自前イメージを作らない理由

WrenAI の CLI / MCP サーバ用のコンテナイメージは見つからなかった(2026-09-21 に確認。upstream の
ファイル一覧に Dockerfile が無く、GHCR の公開パッケージは `wren-ui` / `wren-engine` /
`wren-ai-service` など別構成のものだけだった)。
自前で build して GHCR に置くと private イメージになり pull 用の資格情報が要るので、
**公式の python イメージに initContainer で `pip install` する**形にした。

- 入れる物は `requirements.lock` のハッシュで固定してあり、`--require-hashes --only-binary :all:` で入れる。
  PyPI 側で中身が差し替わればインストールが失敗する
- 代償は起動時間と PyPI への依存。ローカルの同じイメージで install に 58 秒、展開後 710 MB(emptyDir)
  (クラスタでは initContainer が約 80 秒。2026-09-22 実測)
- pip は wheel を `TMPDIR` に展開する。`/tmp`(256Mi)のままだと超過して **pod が evict される**
  (初回デプロイで発生)。`prepare.sh` が `TMPDIR` を 2Gi の emptyDir 側に向けている
- PyPI に届かないと pod は起動できない。動いている pod には影響しない

### lock の更新

```bash
cd wrenai/base
uv pip compile requirements.in --generate-hashes --only-binary :all: \
  --python-version 3.14 --python-platform x86_64-unknown-linux-gnu -o requirements.lock
```

## MDL プロジェクト

`base/project/` が WrenAI のプロジェクトそのもの。手元で `wren` CLI を使って編集・検証できる。

| | |
|---|---|
| model `flows` | **`lakehouse.silver.flows`**(SQLMesh が bronze から毎時作る実データ)。25 列 |
| cube `traffic` | measure 6 つ(`flow_count` / `total_bytes` / `total_packets` / `total_retrans` / `total_drops` / `avg_rtt_ms`)と dimension 9 つ + 時間軸 |
| `knowledge/rules/general.md` | エージェントに渡す業務ルール |

ConfigMap のキーに `/` を使えないため、`base/kustomization.yaml` で `models__flows__metadata.yml` の
ように `__` 区切りで並べ、initContainer(`prepare.sh`)がディレクトリに戻して `wren context build` する。
**ファイルを足したら kustomization にも 1 行足す。** 足し忘れると、そのファイルは pod に入らない。

cube の measure 名を列名と同じにすると循環参照になる(`bytes` ではなく `total_bytes`)。

**bronze ではなく silver を指す。** silver には `proto_name` / `is_cross_node` / `rtt_ms` /
`duration_ms` が実列としてあるので、同じ式を MDL 側にもう一度書かずに済む。定義が
SQLMesh 側に 1 つだけになる。view を持たないのも同じ理由(silver がその役割を果たす)。

## wrenai 0.15.0 で避けていること

いずれも 2026-09-21 に手元で再現させて確認した。upstream には未報告。

1. **`mcp` extra に上限が無い。** そのまま入れると mcp 2.2.0 が入り、`wren serve mcp` が起動しない。
   `requirements.in` で `mcp[cli]<2` に抑えている(入るのは 1.30.0)。
2. **`--host 0.0.0.0` にしても localhost 以外の Host ヘッダが 421 になる。** FastMCP を既定の host
   (127.0.0.1)で生成した後に `settings.host` を書き換えているため、mcp SDK の DNS rebinding 保護が
   localhost 限定のまま残る。`launch.py` が保護を切らずに、環境変数 `WREN_MCP_ALLOWED_HOSTS` の
   名前だけを追加で許可する。**Service 名や Ingress 名を変えたら、この環境変数も直す。**
3. **`wren cube query --filter` は値を常に文字列として引用する。** 整数列に使うと Trino が
   `integer = varchar` で拒否する(CLI では `--from` に JSON を渡せば避けられる)。

`/mcp` は GET に 406 を返すので、probe は HTTP ではなく TCP にしてある。

## 認証は無い

MCP サーバに認証の仕組みは無く、`run_sql` でレイクハウスを読める。守りは次の 2 つ。

- `--allow-write` を付けていない(`store_query` を公開しない)
- CiliumNetworkPolicy で、届く相手を **kubelet の probe と、この app の Tailscale Ingress proxy だけ**に
  絞っている。クラスタ内の他の pod(n8n など)から使うなら `base/ciliumnetworkpolicy.yaml` に
  `fromEndpoints` を足す。相手側に egress の CNP があれば、そちらにも許可が要る

tailnet 側で届く範囲は Tailscale の ACL が決める。

## 繋ぎ方

```bash
claude mcp add --transport http wren https://wren-mcp.example.ts.net/mcp
```
