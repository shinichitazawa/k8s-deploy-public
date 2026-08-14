# litellm — OpenAI 互換 API proxy

100+ LLM provider に統一 OpenAI 互換 API を被せる proxy。商用 API (Bedrock / Anthropic / OpenAI) と self-host OSS (ollama / vLLM) を同じ SDK で切り替え可能にします。

## 構成

- model_list に 4 OSS local endpoint + Bedrock Nova family + Claude family + `ab-router` (round-robin 用)
- router_settings: `simple-shuffle` で `ab-router` 配下の 4 candidate に均等振り分け
- success/failure_callback: Langfuse で全 trace を記録
- `telemetry: false` (BerriAI 開発元への phone-home を遮断、データ主権)

## 依存

- LiteLLM master key Secret (`litellm-credentials` ExternalSecret 経由)
- 上流 model:
  - Bedrock 系: IRSA で `bedrock:InvokeModel` 権限が必要
  - Local ollama: [llm-ab-test/](../llm-ab-test/) が ai-platform ns に居ること

## apply

```bash
kubectl apply -k litellm/overlays/dev
```

## 動作確認

```bash
kubectl -n ai-platform port-forward svc/litellm-proxy 4000:4000 &
curl http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -d '{"model":"ab-router","messages":[{"role":"user","content":"Hi"}]}'

# 4 回叩くと round-robin で別 backend に
```

## 注意

- LiteLLM の `telemetry` は OpenTelemetry とは別物 (BerriAI 集計値送信)。データ主権を取るなら `false` を維持
- OpenTelemetry 連携が必要なら別途 `callbacks: ["otel"]` を追加 (自社 collector に送信)
