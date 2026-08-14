# azure-workload-identity-webhook

Azure **Workload Identity** の Mutating Admission Webhook([Azure/azure-workload-identity](https://github.com/Azure/azure-workload-identity) v1.6.0)。
`azure.workload.identity/use: "true"` ラベルの付いた **Pod** に、keyless 認証に必要な以下を自動注入する:

- projected SA token ボリューム(audience=`api://AzureADTokenExchange`)
- env `AZURE_CLIENT_ID`(SA アノテーション `azure.workload.identity/client-id` 由来)/
  `AZURE_TENANT_ID`(既定は ConfigMap の `AZURE_TENANT_ID`)/ `AZURE_FEDERATED_TOKEN_FILE` / `AZURE_AUTHORITY_HOST`

これにより、Azure を叩く Pod は values に projected token + AZURE_* env を手書きせず、
**SA のラベル/アノテーション + Pod ラベルだけ**で keyless になる。AWS の pod-identity-webhook(IRSA)、
GCP の credential-config(off-GKE は webhook 非存在)に対応する Azure 版。

## 位置づけ / 方式

- **ns**: upstream 既定の `azure-workload-identity-system` ではなく **cluster-ops** に集約(AWS webhook と同居)。
  `namespaceSelector: {}` なので全 ns の対象 Pod をインジェクトできる。
- **cert**: webhook pod が起動時に自己署名 cert を生成し Secret `azure-wi-webhook-server-cert` に書き込み、
  MutatingWebhookConfiguration の caBundle を自己 patch する(自己 bootstrap。cert-manager 不要)。
- **トリガ**: `objectSelector` が **Pod ラベル** `azure.workload.identity/use: "true"` を要求する。
  SA だけでなく **Pod template にもこのラベル**が要る(利用側 values の `podLabels`)。

## 利用側(例: cluster-autoscaler Azure)

```yaml
# SA
rbac.serviceAccount.labels:      { azure.workload.identity/use: "true" }
rbac.serviceAccount.annotations: { azure.workload.identity/client-id: "<app clientID>" }
# Pod(webhook の objectSelector 用。これが無いと注入されない)
podLabels: { azure.workload.identity/use: "true" }
azureUseWorkloadIdentityExtension: true   # chart が ARM_USE_WORKLOAD_IDENTITY_EXTENSION=true を設定
```

webhook が token/env を注入するので、values 側の projected token(`extraVolumes`)や
`AZURE_*`(`extraEnv`)の手動 wiring は**不要**になる。

## 投入

```bash
kubectl --context rpi0-hybrid apply -k azure-workload-identity-webhook/base
# 本筋は ArgoCD self-heal 配下(applications/ に追加)
```

## 更新(バージョン上げ)

```bash
helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts
helm template workload-identity-webhook azure-workload-identity/workload-identity-webhook \
  --version <new> --namespace cluster-ops \
  --set azureTenantID=<tenant> > base/workload-identity-webhook.yaml
```

## 参考

- [Azure Workload Identity](https://azure.github.io/azure-workload-identity/docs/) / issue #13(cluster-autoscaler Azure)
