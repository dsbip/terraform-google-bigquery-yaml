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

variable "lake_bucket" {
  description = "Cloud Storage bucket of the data lake."
  type        = string
  default     = "shop-data-lake"
}

variable "platform_team_group" {
  description = "Group that owns every dataset."
  type        = string
  default     = "data-platform@example.com"
}

variable "analysts_group" {
  description = "Group of the analysts."
  type        = string
  default     = "analysts@example.com"
}

variable "partner_service_account" {
  description = "Service account of the logistics partner."
  type        = string
  default     = "partner-reader@partner-project.iam.gserviceaccount.com"
}

variable "sentiment_service_url" {
  description = "Cloud Run endpoint behind udfs.review_sentiment."
  type        = string
  default     = "https://review-sentiment-abc123-ew.a.run.app"
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  labels = {
    managed_by = "terraform"
  }

  template_vars = {
    lake_bucket             = var.lake_bucket
    platform_team_group     = var.platform_team_group
    analysts_group          = var.analysts_group
    partner_service_account = var.partner_service_account
    sentiment_service_url   = var.sentiment_service_url
  }
}

output "resource_counts" {
  value = module.bigquery.resource_counts
}

output "connections" {
  value = module.bigquery.connections
}
