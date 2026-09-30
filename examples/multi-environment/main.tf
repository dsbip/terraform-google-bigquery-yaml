terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.42.0, < 9.0.0"
    }
  }
}

# Every resource sets its project explicitly, so one provider serves all
# environments (the credentials need access to each project).
provider "google" {}

variable "environments" {
  description = "Settings per environment. The map key becomes $${env} in config.yaml."
  type = map(object({
    project_id         = string
    location           = string
    protect            = bool
    raw_retention_days = number
    analysts_group     = string
  }))
  default = {
    dev = {
      project_id         = "my-analytics-dev"
      location           = "US"
      protect            = false
      raw_retention_days = 7
      analysts_group     = "analysts-dev@example.com"
    }
    prod = {
      project_id         = "my-analytics-prod"
      location           = "US"
      protect            = true
      raw_retention_days = 400
      analysts_group     = "analysts@example.com"
    }
  }
}

module "bigquery" {
  source   = "../.."
  for_each = var.environments

  project_id  = each.value.project_id
  config_file = "${path.module}/config.yaml"

  labels = {
    cost_center = "analytics"
  }

  # Derived values are computed here so that config.yaml only needs plain
  # ${name} placeholders.
  template_vars = {
    env                         = each.key
    location                    = each.value.location
    protect                     = each.value.protect
    delete_contents             = !each.value.protect
    deletion_policy             = each.value.protect ? "PREVENT" : "DELETE"
    raw_partition_expiration_ms = each.value.raw_retention_days * 24 * 60 * 60 * 1000
    analysts_group              = each.value.analysts_group
  }
}

output "datasets" {
  description = "Datasets per environment."
  value       = { for env, m in module.bigquery : env => m.datasets }
}
