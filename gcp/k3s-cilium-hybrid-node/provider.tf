provider "google" {
  project = var.project
  region  = var.region

  default_labels = {
    environment = "dev"
    project     = "k3s-cilium-hybrid-node"
    managedby   = "terraform"
  }
}
