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

variable "hr_team_group" {
  description = "Google group of the HR team (full access to hr_private)."
  type        = string
  default     = "hr-team@example.com"
}

variable "all_employees_group" {
  description = "Google group of all employees (read access to hr_shared)."
  type        = string
  default     = "all-employees@example.com"
}

variable "people_analytics_group" {
  description = "Google group of the people analytics team (read access to hr_analytics)."
  type        = string
  default     = "people-analytics@example.com"
}

module "bigquery" {
  source = "../.."

  project_id  = var.project_id
  config_file = "${path.module}/config.yaml"

  template_vars = {
    hr_team_group          = var.hr_team_group
    all_employees_group    = var.all_employees_group
    people_analytics_group = var.people_analytics_group
  }
}

output "authorized_views" {
  value = module.bigquery.authorized_views
}

output "authorized_datasets" {
  value = module.bigquery.authorized_datasets
}

output "authorized_routines" {
  value = module.bigquery.authorized_routines
}
