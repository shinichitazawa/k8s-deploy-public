# keda — Kubernetes Event-Driven Autoscaler

cluster-level addon。ScaledObject CR で任意 namespace の Deployment を Prometheus trigger 等で 0↔N に scale 制御します。

## 用途

- [llm-ab-test/](../llm-ab-test/) の 4 model deployments を scale-to-zero (cooldown 10 分)
- [vllm-tpu/](../vllm-tpu/) の TPU Deployment を同様に scale-to-zero
- 他の app の event-driven autoscaling

## 依存

なし (Helm chart で完結)

## install

```bash
kubectl apply -k keda/overlays/dev
```

KEDA CRD (`scaledobjects.keda.sh` 等) が cluster-wide に登録され、operator pod が `keda` namespace で起動します。

## バージョン

KEDA v2.20.1 (2026-06-08 release、chart = appVersion)
