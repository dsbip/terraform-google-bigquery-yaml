terraform {
  # 1.5 is the oldest release this module is tested against (see docs/testing.md).
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # 7.42 is the first release with every attribute the module sets
      # (deletion_policy, routine IAM, routine argument table types,
      # connector configurations).
      version = ">= 7.42.0, < 9.0.0"
    }
  }
}
