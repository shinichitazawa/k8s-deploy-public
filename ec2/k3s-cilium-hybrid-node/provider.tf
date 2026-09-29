provider "aws" {
  region = var.region
  # profile が空なら AWS 既定の認証チェーン（env の AWS_ACCESS_KEY_ID 等）を使う。
  # ローカル CLI: profile="example-env"。Burrito(in-cluster): profile="" にして Secret の env creds を使用。
  profile = var.profile != "" ? var.profile : null

  default_tags {
    tags = {
      Environment = "dev"
      Project     = "k3s-cilium-hybrid-node"
      ManagedBy   = "Terraform"
    }
  }
}
