# state は既存 AWS S3 backend を共用（repo 規約）。
# 認証: ローカル CLI は AWS_PROFILE=example-env(backend) + az login(azurerm)。
terraform {
  backend "s3" {
    bucket  = "example-terraform-state"
    key     = "azure/k3s-cilium-hybrid-node/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
  }
}
