provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  # 認証は az CLI(`az login`) / env(ARM_*) / managed identity に委ねる。
}
