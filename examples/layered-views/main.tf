terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.42.0, < 9.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

variable "project_id" {
  description = "Project to create the resources in."
  type        = string
}

# Layer 1: tables and the views that read them.
module "base" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/base.yaml"
}

# Layer 2: views that read layer-1 views. depends_on makes Terraform create
# (and destroy) this layer after (and before) the base layer.
module "marts" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/marts.yaml"

  depends_on = [module.base]
}

output "views" {
  value = merge(module.base.views, module.marts.views)
}
