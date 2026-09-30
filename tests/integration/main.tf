# Live integration test fixture. Deployed into a real project by
# tests/python/test_live.py (see docs/testing.md); everything it creates is
# prefixed with bqyaml_<suffix> and is destroyed at the end of the run.

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
  description = "Project to run the test in. It is left as it was found."
  type        = string
}

variable "suffix" {
  description = "Unique suffix for this run's dataset IDs (lower case letters, digits, underscores)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9_]{1,20}$", var.suffix))
    error_message = "suffix must match ^[a-z0-9_]{1,20}$."
  }
}

variable "location" {
  description = "BigQuery location for the test datasets."
  type        = string
  default     = "US"
}

variable "revision" {
  description = "Changes descriptions only; the test re-applies with a new value to exercise in-place updates."
  type        = number
  default     = 1
}

variable "test_member" {
  description = "Optional IAM member (e.g. serviceAccount:ci@p.iam.gserviceaccount.com) that receives table, routine and connection IAM grants."
  type        = string
  default     = ""
}

variable "enable_connections" {
  description = "Also create a connection (needs bigqueryconnection.googleapis.com)."
  type        = bool
  default     = false
}

variable "enable_transfers" {
  description = "Also create a disabled scheduled query (needs bigquerydatatransfer.googleapis.com)."
  type        = bool
  default     = false
}

locals {
  template_vars = {
    suffix      = var.suffix
    location    = var.location
    revision    = var.revision
    test_member = var.test_member
  }
}

# Datasets, tables, views, materialized views, routines, access grants and
# authorized views/datasets/routines.
module "core" {
  source = "../.."

  project_id    = var.project_id
  config_file   = "${path.module}/core.yaml"
  template_vars = local.template_vars
  labels = {
    purpose = "terraform-module-test"
  }
}

# Table and routine IAM for test_member.
module "iam" {
  source = "../.."
  count  = var.test_member == "" ? 0 : 1

  project_id    = var.project_id
  config_file   = "${path.module}/iam.yaml"
  template_vars = local.template_vars

  depends_on = [module.core]
}

module "connections" {
  source = "../.."
  count  = var.enable_connections ? 1 : 0

  project_id    = var.project_id
  config_file   = "${path.module}/connections.yaml"
  template_vars = local.template_vars
}

module "transfers" {
  source = "../.."
  count  = var.enable_transfers ? 1 : 0

  project_id    = var.project_id
  config_file   = "${path.module}/transfers.yaml"
  template_vars = local.template_vars

  depends_on = [module.core]
}

output "resource_counts" {
  value = {
    core        = module.core.resource_counts
    iam         = try(module.iam[0].resource_counts, null)
    connections = try(module.connections[0].resource_counts, null)
    transfers   = try(module.transfers[0].resource_counts, null)
  }
}

output "datasets" {
  value = module.core.datasets
}

output "views" {
  value = module.core.views
}

output "routines" {
  value = module.core.routines
}

output "connections" {
  value = try(module.connections[0].connections, {})
}
