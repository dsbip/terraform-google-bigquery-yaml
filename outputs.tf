output "project_id" {
  description = "Default project resolved from the YAML project_id or the project_id variable."
  value       = local.project_id
}

output "datasets" {
  description = "Datasets created by the module, keyed by YAML key."
  value = {
    for k, d in google_bigquery_dataset.this : k => {
      id         = d.id
      project    = d.project
      dataset_id = d.dataset_id
      location   = d.location
      self_link  = d.self_link
    }
  }
}

output "tables" {
  description = "Tables, keyed by \"<dataset key>.<table key>\"."
  value = {
    for k, t in google_bigquery_table.table : k => {
      id         = t.id
      project    = t.project
      dataset_id = t.dataset_id
      table_id   = t.table_id
      self_link  = t.self_link
    }
  }
}

output "views" {
  description = "Logical views, keyed by \"<dataset key>.<view key>\"."
  value = {
    for k, t in google_bigquery_table.view : k => {
      id         = t.id
      project    = t.project
      dataset_id = t.dataset_id
      table_id   = t.table_id
      self_link  = t.self_link
    }
  }
}

output "materialized_views" {
  description = "Materialized views, keyed by \"<dataset key>.<view key>\"."
  value = {
    for k, t in google_bigquery_table.materialized_view : k => {
      id         = t.id
      project    = t.project
      dataset_id = t.dataset_id
      table_id   = t.table_id
      self_link  = t.self_link
    }
  }
}

output "routines" {
  description = "Routines, keyed by \"<dataset key>.<routine key>\"."
  value = {
    for k, r in google_bigquery_routine.this : k => {
      id           = r.id
      project      = r.project
      dataset_id   = r.dataset_id
      routine_id   = r.routine_id
      routine_type = r.routine_type
    }
  }
}

output "connections" {
  description = "Connections, keyed by YAML key. service_account_id is the Google-managed identity to grant access to (cloud_resource, spark, cloud_sql and connector connections); identity is the AWS/Azure identity."
  value = {
    for k, c in google_bigquery_connection.this : k => {
      id            = c.id
      name          = c.name
      project       = c.project
      location      = c.location
      connection_id = c.connection_id
      service_account_id = try(coalesce(
        try(c.cloud_resource[0].service_account_id, null),
        try(c.spark[0].service_account_id, null),
        try(c.cloud_sql[0].service_account_id, null),
        try(c.configuration[0].authentication[0].service_account, null),
      ), null)
      identity = try(coalesce(
        try(c.aws[0].access_role[0].identity, null),
        try(c.azure[0].identity, null),
      ), null)
    }
  }
}

output "transfers" {
  description = "Data transfer configs, keyed by YAML key."
  value = {
    for k, t in google_bigquery_data_transfer_config.this : k => {
      id             = t.id
      name           = t.name
      display_name   = t.display_name
      data_source_id = t.data_source_id
      location       = t.location
    }
  }
}

output "dataset_access" {
  description = "Dataset access grants, keyed by \"<dataset key>|<role>|<member>\"."
  value = {
    for k, a in google_bigquery_dataset_access.access : k => {
      dataset_id = a.dataset_id
      role       = a.role
      member     = local.dataset_access[k].member
    }
  }
}

output "authorized_views" {
  description = "Authorized views, keyed by \"<source dataset key>|<project>.<dataset>.<view>\"."
  value       = { for k, a in google_bigquery_dataset_access.authorized_view : k => a.id }
}

output "authorized_datasets" {
  description = "Authorized datasets, keyed by \"<source dataset key>|<project>.<dataset>\"."
  value       = { for k, a in google_bigquery_dataset_access.authorized_dataset : k => a.id }
}

output "authorized_routines" {
  description = "Authorized routines, keyed by \"<source dataset key>|<project>.<dataset>.<routine>\"."
  value       = { for k, a in google_bigquery_dataset_access.authorized_routine : k => a.id }
}

output "resource_counts" {
  description = "Number of resources of each kind declared by the configuration."
  value = {
    datasets               = length(google_bigquery_dataset.this)
    tables                 = length(google_bigquery_table.table)
    views                  = length(google_bigquery_table.view)
    materialized_views     = length(google_bigquery_table.materialized_view)
    routines               = length(google_bigquery_routine.this)
    connections            = length(google_bigquery_connection.this)
    transfers              = length(google_bigquery_data_transfer_config.this)
    dataset_access         = length(google_bigquery_dataset_access.access)
    authorized_views       = length(google_bigquery_dataset_access.authorized_view)
    authorized_datasets    = length(google_bigquery_dataset_access.authorized_dataset)
    authorized_routines    = length(google_bigquery_dataset_access.authorized_routine)
    table_iam_members      = length(google_bigquery_table_iam_member.this)
    routine_iam_members    = length(google_bigquery_routine_iam_member.this)
    connection_iam_members = length(google_bigquery_connection_iam_member.this)
  }
}
