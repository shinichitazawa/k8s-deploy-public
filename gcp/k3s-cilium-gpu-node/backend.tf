# state は既存 AWS S3 backend を共用（repo 規約）。GCP リソースでも state 保存先は独立でよい。
# 認証: ローカル CLI は `AWS_PROFILE=example-env`（backend 用）+ gcloud ADC（google provider 用）。
terraform {
  backend "s3" {
    bucket  = "example-terraform-state"
    key     = "gcp/k3s-cilium-gpu-node/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
  }
}
