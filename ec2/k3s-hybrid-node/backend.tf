# S3 backend (repo 既存規約に合わせる)。
# Terrakube から実行する場合は Terrakube 側の remote state / backend override を使ってもよい。
# backend の認証は profile を固定せず AWS 既定チェーンに委ねる。
#   ローカル CLI: `AWS_PROFILE=example-env terraform ...`
#   Burrito(in-cluster): Secret の AWS_ACCESS_KEY_ID/SECRET(env)
terraform {
  backend "s3" {
    bucket  = "example-terraform-state"
    key     = "ec2/k3s-hybrid-node/terraform.tfstate"
    region  = "ap-northeast-1"
    encrypt = true
  }
}
