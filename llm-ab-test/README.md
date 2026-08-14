# llm-ab-test — 4 OSS LLM 並行 A/B test 基盤

商用 LLM API への依存を減らす目的で、4 つの OSS LLM (Sarashina2.1-3B / PLaMo 2 8B / Phi-4-mini / GPT-OSS-20B) を EKS 上で並列起動し、LiteLLM Router 経由で round-robin 振り分けする A/B 評価基盤です。

## 構成

- ollama (CPU 推論) で 4 model を Deployment として並列起動
- Karpenter NodePool で Graviton3 (c7g) インスタンスを spot 優先で provision
- KEDA ScaledObject (Prometheus trigger) で scale-to-zero、リクエスト無し時は Pod 0
- judge-prompt ConfigMap で 4-way / 5-way LLM-as-judge 用のプロンプトを管理

## 依存

- EKS Auto Mode (Karpenter 内蔵)
- KEDA v2.20+ ([keda/](../keda/) で別途 install)
- LiteLLM proxy ([litellm/](../litellm/))
- Prometheus (KEDA trigger 用)
- (任意) Langfuse (inference trace 用)

## apply

```bash
kubectl apply -k llm-ab-test/overlays/dev
```

## モデル選定の考え方

| # | Model | License | サイズ | 強み |
|---|---|---|---|---|
| 1 | Sarashina2.1-3B-Instruct | MIT | 3B | 日本語特化 |
| 2 | PLaMo 2 8B Instruct | Apache 2.0 | 8B | 日本語特化、HF gate なし |
| 3 | Phi-4-mini Instruct | MIT | 3.8B | 128K context、多言語 |
| 4 | GPT-OSS-20B | Apache 2.0 | 21B (MoE active 3.6B) | agentic / tool use |

ライセンスは Apache 2.0 / MIT に絞り、商用ライセンス交渉が不要な構成です。

## 注意

- Sarashina / PLaMo は HuggingFace の gated repository から pull する場合、HF token Secret の事前注入が必要
- ollama は version 0.30+ で GPT-OSS をサポート (古い版では pull 失敗)
- NodePool は EKS Auto Mode 用に `eks.amazonaws.com/instance-family` ラベルを使用
