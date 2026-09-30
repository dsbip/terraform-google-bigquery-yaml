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

variable "landing_bucket" {
  description = "Cloud Storage bucket holding the files behind the external tables."
  type        = string
  default     = "my-landing-bucket"
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    landing_bucket = var.landing_bucket
  }
}

output "tables" {
  value = module.bigquery.tables
}
