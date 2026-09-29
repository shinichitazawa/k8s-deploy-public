# burrito-runner IAM ポリシー（bootstrap 資格情報）

`burrito-runner-policy.json` は、Burrito(in-cluster GitOps) の runner が使う IAM ユーザー
`burrito-runner` に付与する権限定義です。

## なぜ imperative（このファイル＋aws-cli）で管理するか

これは **GitOps の bootstrap 資格情報**そのものです。Burrito 自身を動かすための鍵なので、
Burrito(や ACK/Kro)で管理すると循環します（鍵を管理する鍵が必要になり、irreducible な種は消えない）。
そのため **1 個の最小 imperative な種**として割り切り、内容だけ本ファイルで追跡可能にしています。

将来、EC2 ノードの **instance profile**（`ec2/k3s-hybrid-node` で付与）で Burrito runner を回せば、
この静的キー自体を廃止できます（pod は IMDS で assume）。

## 適用方法（customer managed policy）

インライン上限(2048B)を超えるため managed policy を使用:

```bash
ACC=<account-id>
# 新規
aws --profile example-env iam create-policy \
  --policy-name burrito-runner-policy \
  --policy-document file://burrito-runner-policy.json
aws --profile example-env iam attach-user-policy \
  --user-name burrito-runner \
  --policy-arn arn:aws:iam::$ACC:policy/burrito-runner-policy

# 更新（新バージョンを default に）
aws --profile example-env iam create-policy-version \
  --policy-arn arn:aws:iam::$ACC:policy/burrito-runner-policy \
  --policy-document file://burrito-runner-policy.json --set-as-default
```

## 権限の要旨（最小権限・ap-northeast-1 限定）

- `ec2:*` / `autoscaling:*`（region 限定）— ノード ASG 管理
- ASG/Spot の service-linked role 作成
- ノード用 IAM ロール/instance profile 管理（`ec2-t4g-*` 限定）＋ `iam:PassRole`
- SSM（Ubuntu AMI パラメータ読取）
- S3: terraform state / Burrito datastore / デモ用 `example-burrito-demo-*`
