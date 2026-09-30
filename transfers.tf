# -----------------------------------------------------------------------------
# Data transfers (scheduled queries, Cloud Storage, Amazon S3, ...)
#
# destination_dataset_id may be a dataset key from this file; the location then
# defaults to that dataset's location, which scheduled queries require.
# -----------------------------------------------------------------------------

locals {
  transfers_input = try(merge({}, local.config.transfers), {})

  transfers_raw = {
    for k, v in local.transfers_input : k => { for kk, vv in try(merge({}, v), {}) : kk => vv if vv != null }
  }

  transfers_merged = {
    for k, raw in local.transfers_raw : k => merge(local.builtin_defaults.transfers, local.type_defaults.transfers, raw)
  }

  transfer_file_paths = {
    for k, m in local.transfers_merged :
    "transfers|${k}|query_file" => (
      startswith(m.query_file, "/") || can(regex("^[A-Za-z]:", m.query_file))
      ? m.query_file
      : "${local.base_path}/${m.query_file}"
    )
    if can(tostring(m.query_file))
  }

  transfers = {
    for k, m in local.transfers_merged : k => {
      path           = "transfers.${k}"
      project        = try(tostring(m.project_id), local.project_id)
      display_name   = try(tostring(m.display_name), k)
      data_source_id = try(tostring(m.data_source_id), null)
      destination_dataset_id = try(
        local.datasets[m.destination_dataset_id].dataset_id,
        tostring(m.destination_dataset_id),
        null
      )
      location = try(
        tostring(local.transfers_raw[k].location),
        tostring(local.datasets[m.destination_dataset_id].location),
        tostring(local.type_defaults.transfers.location),
        local.default_location
      )
      schedule                  = try(m.schedule, null)
      disabled                  = try(m.disabled, null)
      data_refresh_window_days  = try(m.data_refresh_window_days, null)
      notification_pubsub_topic = try(m.notification_pubsub_topic, null)
      service_account_name      = try(m.service_account_name, null)
      deletion_policy           = try(m.deletion_policy, null)

      # query / query_file are shortcuts for params.query.
      params = merge(
        try({ for pk, pv in merge({}, m.params) : pk => tostring(pv) if pv != null }, {}),
        { for q in [try(local.file_contents["transfers|${k}|query_file"], tostring(m.query), null)] : "query" => q if q != null },
      )

      schedule_options = [
        for s in try([merge({}, m.schedule_options)], []) : {
          disable_auto_scheduling = try(s.disable_auto_scheduling, null)
          start_time              = try(s.start_time, null)
          end_time                = try(s.end_time, null)
        }
      ]
      email_preferences = [
        for e in try([merge({}, m.email_preferences)], []) : {
          enable_failure_email = try(tobool(e.enable_failure_email), false)
        }
      ]
      encryption_configuration = [
        for c in try([merge({}, m.encryption_configuration)], []) : {
          kms_key_name = try(c.kms_key_name, null)
        }
      ]
      sensitive_params = [
        for s in try([merge({}, m.sensitive_params)], []) : {
          secret_access_key_secret = try(s.secret_access_key_secret, null)
        }
      ]
    }
  }
}

resource "google_bigquery_data_transfer_config" "this" {
  for_each = { for k, v in local.transfers : k => v if local.config_valid }

  project                   = each.value.project
  location                  = each.value.location
  display_name              = each.value.display_name
  data_source_id            = each.value.data_source_id
  destination_dataset_id    = each.value.destination_dataset_id
  schedule                  = each.value.schedule
  disabled                  = each.value.disabled
  data_refresh_window_days  = each.value.data_refresh_window_days
  notification_pubsub_topic = each.value.notification_pubsub_topic
  service_account_name      = each.value.service_account_name
  deletion_policy           = each.value.deletion_policy
  params                    = each.value.params

  dynamic "schedule_options" {
    for_each = each.value.schedule_options
    content {
      disable_auto_scheduling = schedule_options.value.disable_auto_scheduling
      start_time              = schedule_options.value.start_time
      end_time                = schedule_options.value.end_time
    }
  }

  dynamic "email_preferences" {
    for_each = each.value.email_preferences
    content {
      enable_failure_email = email_preferences.value.enable_failure_email
    }
  }

  dynamic "encryption_configuration" {
    for_each = each.value.encryption_configuration
    content {
      kms_key_name = encryption_configuration.value.kms_key_name
    }
  }

  dynamic "sensitive_params" {
    for_each = each.value.sensitive_params
    content {
      secret_access_key = try(var.secrets[sensitive_params.value.secret_access_key_secret], null)
    }
  }

  # Scheduled queries are validated on creation, so their tables must exist.
  depends_on = [
    terraform_data.validation,
    google_bigquery_dataset.this,
    google_bigquery_table.table,
    google_bigquery_table.materialized_view,
    google_bigquery_table.view,
    google_bigquery_routine.this,
  ]
}
