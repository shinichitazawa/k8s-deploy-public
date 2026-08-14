# pod-identity-webhook

[amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) を **自前 k3s に self-host** し、EKS の IRSA と同じ「SA アノテーションだけで pod に AWS creds 自動注入」を実現する。

## 何をするか

ServiceAccount に `eks.amazonaws.com/role-arn: <role>` を付けると、その SA の pod に
webhook が以下を自動注入する（[README](https://github.com/aws/amazon-eks-pod-identity-webhook)）:

- env `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE`
- projected SA token（audience `sts.amazonaws.com`）を `/var/run/secrets/eks.amazonaws.com/serviceaccount/token` に

pod の AWS SDK はこれを使い `AssumeRoleWithWebIdentity` で keyless にロールを引き受ける。
基盤(OIDC issuer 公開 / IAM OIDC provider)は `docs/hybrid-oidc-irsa-ack.md`、機序は skill [[k3s-irsa]]。

## 前提

- **cert-manager**（webhook の serving 証明書。v1.21.0 を導入済み）。`ClusterIssuer/selfsigned` を使う。
- 基盤の OIDC/IRSA（issuer 公開 + IAM OIDC provider）が構築済みであること。

## 構成

```
base/
  pod-identity-webhook.yaml   SA/RBAC + Deployment(image v0.6.17) + Service + Certificate + MutatingWebhookConfiguration
  kustomization.yaml
```

- ns: **cluster-ops**（運用ツール集約先。upstream の `default` を置換）。
- Deployment 引数: `--in-cluster=false --namespace=cluster-ops --token-audience=sts.amazonaws.com
  --annotation-prefix=eks.amazonaws.com`。
- 証明書: cert-manager `Certificate/pod-identity-webhook`(secret `pod-identity-webhook-cert`)、
  MutatingWebhookConfiguration に `cert-manager.io/inject-ca-from` で caBundle 注入。

## 投入

```bash
# 前提: cert-manager 導入済み
kubectl --context rpi0-hybrid apply -k pod-identity-webhook/base
```

## 検証（実施済み 2026-07）

`eks.amazonaws.com/role-arn` を付けた SA の pod で、静的キー無しに
`aws sts get-caller-identity` が assumed-role を返すことを確認済み。

## 注意

- upstream マニフェストを `default`→`cluster-ops` 置換 + image を v0.6.17 に固定して vendoring している。
  更新時は upstream の `deploy/` と差分を取る。
- image は `public.ecr.aws/eks/amazon-eks-pod-identity-webhook:v0.6.17`。

## 参考

- [amazon-eks-pod-identity-webhook](https://github.com/aws/amazon-eks-pod-identity-webhook) / [SELF_HOSTED_SETUP](https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md)
- [cert-manager](https://cert-manager.io/)
