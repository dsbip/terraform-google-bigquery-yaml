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
  default     = "my-data-lake"
}

variable "analysts_group" {
  description = "Google group allowed to use the lake connection."
  type        = string
  default     = "analysts@example.com"
}

variable "orders_db_password" {
  description = "Password of the bq_reader user in the orders Cloud SQL database."
  type        = string
  sensitive   = true
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    lake_bucket    = var.lake_bucket
    analysts_group = var.analysts_group
  }

  secrets = {
    orders_db_password = var.orders_db_password
  }
}

# The lake connection's Google-managed service account needs read access to
# the bucket before the BigLake and object tables can be queried.
resource "google_storage_bucket_iam_member" "lake_reader" {
  bucket = var.lake_bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.bigquery.connections["lake"].service_account_id}"
}

output "connections" {
  value = module.bigquery.connections
}
