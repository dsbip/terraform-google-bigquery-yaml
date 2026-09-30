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
  description = "Project that holds legacy_warehouse and where new datasets are created."
  type        = string
}

variable "reference_project" {
  description = "Project that holds the reference_data dataset."
  type        = string
  default     = "shared-reference-data"
}

variable "marketing_group" {
  description = "Google group of the marketing analysts."
  type        = string
  default     = "marketing-analysts@example.com"
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    reference_project = var.reference_project
    marketing_group   = var.marketing_group
  }
}

output "datasets" {
  description = "Only marketing: the other two datasets are not created here."
  value       = module.bigquery.datasets
}

output "tables" {
  value = module.bigquery.tables
}
