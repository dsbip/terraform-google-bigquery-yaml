# Every example configuration, planned through the module with the template
# variables its main.tf passes. Each run checks the exact number of resources of
# every kind, so an example cannot silently lose or gain resources.

mock_provider "google" {}

variables {
  project_id = "example-project"
}

run "basic" {
  command = plan

  variables {
    config_file = "examples/basic/config.yaml"
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 2, views = 1, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 1, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition     = strcontains(google_bigquery_table.view["sales.revenue_by_country"].view[0].query, "`example-project.sales.orders`")
    error_message = "The project_id placeholder was not rendered."
  }
}

run "tables_and_schemas" {
  command = plan

  variables {
    config_file   = "examples/tables-and-schemas/config.yaml"
    template_vars = { landing_bucket = "landing-bucket" }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 2, tables = 9, views = 0, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 0, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition     = google_bigquery_table.table["landing.daily_orders_csv"].external_data_configuration[0].source_uris == tolist(["gs://landing-bucket/orders/*.csv"])
    error_message = "The landing_bucket placeholder was not rendered."
  }
  assert {
    condition     = google_bigquery_table.table["events.purchases"].table_constraints[0].foreign_keys[0].referenced_table[0].table_id == "users"
    error_message = "The foreign key did not resolve to events.users."
  }
}

run "authorized_views" {
  command = plan

  variables {
    config_file = "examples/authorized-views/config.yaml"
    template_vars = {
      hr_team_group          = "hr@example.com"
      all_employees_group    = "all@example.com"
      people_analytics_group = "people-analytics@example.com"
    }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 3, tables = 1, views = 3, materialized_views = 0, routines = 1, connections = 0, transfers = 0,
      dataset_access    = 3, authorized_views = 2, authorized_datasets = 1, authorized_routines = 1,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
}

run "routines" {
  command = plan

  variables {
    config_file   = "examples/routines/config.yaml"
    template_vars = { language_service_url = "https://svc.run.app" }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 2, views = 0, materialized_views = 0, routines = 8, connections = 1, transfers = 0,
      dataset_access    = 1, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 1, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition     = strcontains(google_bigquery_routine.this["udfs.archive_cancelled_orders"].definition_body, "`example-project.udfs.orders`")
    error_message = "The procedure template was not rendered."
  }
}

run "scheduled_queries" {
  command = plan

  variables {
    config_file   = "examples/scheduled-queries/config.yaml"
    template_vars = { partner_bucket = "partner-bucket", aws_access_key_id = "AKIA" }
    secrets       = { aws_secret_access_key = "secret" }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 2, tables = 4, views = 0, materialized_views = 0, routines = 0, connections = 0, transfers = 5,
      dataset_access    = 0, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition     = google_bigquery_data_transfer_config.this["daily_revenue"].location == "US" && google_bigquery_data_transfer_config.this["daily_revenue"].destination_dataset_id == "reporting"
    error_message = "The daily_revenue transfer should take its location from the reporting dataset."
  }
}

run "connections" {
  command = plan

  variables {
    config_file   = "examples/connections/config.yaml"
    template_vars = { lake_bucket = "lake", analysts_group = "analysts@example.com" }
    secrets       = { orders_db_password = "pw" }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 3, views = 0, materialized_views = 0, routines = 1, connections = 6, transfers = 0,
      dataset_access    = 0, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 1,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
}

run "existing_datasets" {
  command = plan

  variables {
    config_file   = "examples/existing-datasets/config.yaml"
    template_vars = { reference_project = "reference", marketing_group = "marketing@example.com" }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 1, views = 1, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 2, authorized_views = 1, authorized_datasets = 1, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition = (
      google_bigquery_dataset_access.authorized_view["reference|example-project.marketing.campaign_performance"].project == "reference" &&
      google_bigquery_dataset_access.authorized_view["reference|example-project.marketing.campaign_performance"].dataset_id == "reference_data"
    )
    error_message = "The authorization should be added to the reference project's dataset."
  }
}

run "layered_views_base" {
  command = plan

  variables {
    config_file = "examples/layered-views/base.yaml"
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 1, views = 1, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 0, authorized_views = 0, authorized_datasets = 0, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
}

run "layered_views_marts" {
  command = plan

  variables {
    config_file = "examples/layered-views/marts.yaml"
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 1, tables = 0, views = 2, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 1, authorized_views = 0, authorized_datasets = 1, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
}

run "multi_environment_prod" {
  command = plan

  variables {
    project_id  = "my-analytics-prod"
    config_file = "examples/multi-environment/config.yaml"
    template_vars = {
      env                         = "prod"
      location                    = "US"
      protect                     = true
      delete_contents             = false
      deletion_policy             = "PREVENT"
      raw_partition_expiration_ms = 400 * 24 * 60 * 60 * 1000
      analysts_group              = "analysts@example.com"
    }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 2, tables = 1, views = 1, materialized_views = 0, routines = 0, connections = 0, transfers = 0,
      dataset_access    = 1, authorized_views = 0, authorized_datasets = 1, authorized_routines = 0,
      table_iam_members = 0, routine_iam_members = 0, connection_iam_members = 0,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition = (
      google_bigquery_dataset.this["raw"].dataset_id == "raw_prod" &&
      google_bigquery_dataset.this["raw"].deletion_policy == "PREVENT" &&
      google_bigquery_dataset.this["raw"].delete_contents_on_destroy == false &&
      google_bigquery_dataset.this["raw"].default_partition_expiration_ms == 34560000000 &&
      google_bigquery_table.table["raw.customers"].deletion_protection == true
    )
    error_message = "Production settings were not rendered."
  }
  assert {
    condition     = strcontains(google_bigquery_table.view["curated.customers"].view[0].query, "`my-analytics-prod.raw_prod.customers`")
    error_message = "The SQL template should use the environment's dataset ID."
  }
}

run "multi_environment_dev" {
  command = plan

  variables {
    project_id  = "my-analytics-dev"
    config_file = "examples/multi-environment/config.yaml"
    template_vars = {
      env                         = "dev"
      location                    = "US"
      protect                     = false
      delete_contents             = true
      deletion_policy             = "DELETE"
      raw_partition_expiration_ms = 7 * 24 * 60 * 60 * 1000
      analysts_group              = "analysts-dev@example.com"
    }
  }

  assert {
    condition = (
      google_bigquery_dataset.this["raw"].dataset_id == "raw_dev" &&
      google_bigquery_dataset.this["curated"].dataset_id == "curated_dev" &&
      google_bigquery_table.table["raw.customers"].deletion_protection == false &&
      google_bigquery_dataset.this["raw"].labels["environment"] == "dev"
    )
    error_message = "Development settings were not rendered."
  }
}

run "complete" {
  command = plan

  variables {
    config_file = "examples/complete/config.yaml"
    labels      = { managed_by = "terraform" }
    template_vars = {
      lake_bucket             = "lake"
      platform_team_group     = "platform@example.com"
      analysts_group          = "analysts@example.com"
      partner_service_account = "partner@partner.iam.gserviceaccount.com"
      sentiment_service_url   = "https://svc.run.app"
    }
  }

  assert {
    condition = output.resource_counts == {
      datasets          = 5, tables = 5, views = 3, materialized_views = 1, routines = 5, connections = 2, transfers = 3,
      dataset_access    = 7, authorized_views = 1, authorized_datasets = 1, authorized_routines = 1,
      table_iam_members = 1, routine_iam_members = 0, connection_iam_members = 1,
    }
    error_message = "Unexpected resources: ${jsonencode(output.resource_counts)}"
  }
  assert {
    condition = alltrue([
      for d in google_bigquery_dataset.this : d.labels["managed_by"] == "terraform" && d.labels["platform"] == "shop-analytics"
    ])
    error_message = "Every dataset should carry the common and default labels."
  }
}
