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

variable "language_service_url" {
  description = "HTTPS endpoint of the Cloud Run service behind the detect_language remote function."
  type        = string
  default     = "https://detect-language-abc123-uc.a.run.app"
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    language_service_url = var.language_service_url
  }
}

output "routines" {
  value = module.bigquery.routines
}

output "remote_connection_service_account" {
  description = "Grant this identity roles/run.invoker on the Cloud Run service."
  value       = module.bigquery.connections["remote"].service_account_id
}
