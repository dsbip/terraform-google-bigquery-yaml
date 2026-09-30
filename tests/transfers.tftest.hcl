# Data transfer configs: scheduled queries and file loads.

mock_provider "google" {}

variables {
  project_id = "test-project"
  base_path  = "tests/fixtures"
  secrets = {
    aws_secret = "wJalrXUtnFEMI"
  }
}

run "scheduled_queries" {
  command = plan

  variables {
    template_vars = { env = "test" }
    config_yaml   = <<-EOT
      defaults:
        location: US
        transfers:
          email_preferences: { enable_failure_email: true }
          notification_pubsub_topic: projects/test-project/topics/transfers
      datasets:
        events:
          dataset_id: events_test
          location: EU
      transfers:
        rollup:
          data_source_id: scheduled_query
          destination_dataset_id: events       # dataset key in this file
          schedule: every day 02:00
          query_file: sql/latest.sql.tftpl
          params:
            destination_table_name_template: "rollup_{run_date}"
            write_disposition: WRITE_TRUNCATE
            partitioning_field: ""
        dml:
          display_name: Nightly MERGE
          data_source_id: scheduled_query
          location: asia-northeast1
          schedule: every 24 hours
          disabled: true
          service_account_name: sq@test-project.iam.gserviceaccount.com
          query: MERGE t USING s ON TRUE WHEN MATCHED THEN DELETE
          schedule_options:
            disable_auto_scheduling: false
            start_time: "2026-11-01T00:00:00Z"
            end_time: "2026-12-01T00:00:00Z"
          email_preferences: { enable_failure_email: false }
          encryption_configuration:
            kms_key_name: projects/p/locations/asia-northeast1/keyRings/r/cryptoKeys/k
        params_only:
          data_source_id: scheduled_query
          destination_dataset_id: not_managed
          params:
            query: SELECT 1
    EOT
  }

  assert {
    condition = (
      google_bigquery_data_transfer_config.this["rollup"].display_name == "rollup" &&
      google_bigquery_data_transfer_config.this["rollup"].destination_dataset_id == "events_test" &&
      google_bigquery_data_transfer_config.this["rollup"].location == "EU" &&
      google_bigquery_data_transfer_config.this["rollup"].project == "test-project"
    )
    error_message = "A managed destination dataset should provide the dataset ID and the location."
  }
  assert {
    condition = google_bigquery_data_transfer_config.this["rollup"].params == tomap({
      query                           = "SELECT * FROM `test-project.events_test.raw` WHERE env = 'test'\n"
      destination_table_name_template = "rollup_{run_date}"
      write_disposition               = "WRITE_TRUNCATE"
      partitioning_field              = ""
    })
    error_message = "params should include the rendered query_file: ${jsonencode(google_bigquery_data_transfer_config.this["rollup"].params)}"
  }
  assert {
    condition = (
      google_bigquery_data_transfer_config.this["rollup"].email_preferences[0].enable_failure_email == true &&
      google_bigquery_data_transfer_config.this["rollup"].notification_pubsub_topic == "projects/test-project/topics/transfers"
    )
    error_message = "defaults.transfers were not applied."
  }
  assert {
    condition = (
      google_bigquery_data_transfer_config.this["dml"].display_name == "Nightly MERGE" &&
      google_bigquery_data_transfer_config.this["dml"].location == "asia-northeast1" &&
      google_bigquery_data_transfer_config.this["dml"].destination_dataset_id == null &&
      google_bigquery_data_transfer_config.this["dml"].disabled == true &&
      google_bigquery_data_transfer_config.this["dml"].service_account_name == "sq@test-project.iam.gserviceaccount.com" &&
      google_bigquery_data_transfer_config.this["dml"].params["query"] == "MERGE t USING s ON TRUE WHEN MATCHED THEN DELETE"
    )
    error_message = "The DML scheduled query is wrong."
  }
  assert {
    condition = (
      google_bigquery_data_transfer_config.this["dml"].schedule_options[0].start_time == "2026-11-01T00:00:00Z" &&
      google_bigquery_data_transfer_config.this["dml"].schedule_options[0].end_time == "2026-12-01T00:00:00Z" &&
      google_bigquery_data_transfer_config.this["dml"].email_preferences[0].enable_failure_email == false &&
      google_bigquery_data_transfer_config.this["dml"].encryption_configuration[0].kms_key_name == "projects/p/locations/asia-northeast1/keyRings/r/cryptoKeys/k"
    )
    error_message = "Transfer options are wrong."
  }
  assert {
    condition = (
      google_bigquery_data_transfer_config.this["params_only"].destination_dataset_id == "not_managed" &&
      google_bigquery_data_transfer_config.this["params_only"].location == "US" &&
      google_bigquery_data_transfer_config.this["params_only"].params["query"] == "SELECT 1"
    )
    error_message = "An unmanaged destination should be used as written, with defaults.location."
  }
}

run "file_loads_and_secrets" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        transfers:
          location: US
      transfers:
        gcs:
          data_source_id: google_cloud_storage
          destination_dataset_id: landing
          schedule: every 24 hours
          data_refresh_window_days: 0
          params:
            data_path_template: gs://bucket/orders/*.csv
            destination_table_name_template: orders
            file_format: CSV
            skip_leading_rows: 1
            max_bad_records: 0
            delete_source_files: false
        s3:
          data_source_id: amazon_s3
          destination_dataset_id: landing
          params:
            data_path: s3://bucket/orders/*.csv
            destination_table_name_template: orders
            access_key_id: AKIA123
          sensitive_params:
            secret_access_key_secret: aws_secret
          deletion_policy: ABANDON
    EOT
  }

  assert {
    condition = google_bigquery_data_transfer_config.this["gcs"].params == tomap({
      data_path_template              = "gs://bucket/orders/*.csv"
      destination_table_name_template = "orders"
      file_format                     = "CSV"
      skip_leading_rows               = "1"
      max_bad_records                 = "0"
      delete_source_files             = "false"
    })
    error_message = "Numeric and boolean params should be converted to strings."
  }
  assert {
    condition = (
      google_bigquery_data_transfer_config.this["gcs"].location == "US" &&
      google_bigquery_data_transfer_config.this["gcs"].data_refresh_window_days == 0
    )
    error_message = "defaults.transfers.location or data_refresh_window_days is wrong."
  }
  assert {
    condition = (
      nonsensitive(google_bigquery_data_transfer_config.this["s3"].sensitive_params[0].secret_access_key) == "wJalrXUtnFEMI" &&
      google_bigquery_data_transfer_config.this["s3"].deletion_policy == "ABANDON"
    )
    error_message = "The S3 secret was not taken from the secrets variable."
  }
}
