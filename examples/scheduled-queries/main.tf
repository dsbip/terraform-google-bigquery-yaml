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

variable "partner_bucket" {
  description = "Cloud Storage bucket the partner drops CSV exports into."
  type        = string
  default     = "partner-exports-bucket"
}

variable "aws_access_key_id" {
  description = "AWS access key ID for the S3 transfer."
  type        = string
  default     = "AKIAEXAMPLEKEY"
}

variable "aws_secret_access_key" {
  description = "AWS secret access key for the S3 transfer."
  type        = string
  sensitive   = true
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    partner_bucket    = var.partner_bucket
    aws_access_key_id = var.aws_access_key_id
  }

  # Referenced by name from sensitive_params.secret_access_key_secret.
  secrets = {
    aws_secret_access_key = var.aws_secret_access_key
  }
}

output "transfers" {
  value = module.bigquery.transfers
}
