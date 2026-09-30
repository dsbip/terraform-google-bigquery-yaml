# Transfers and scheduled queries

`transfers` creates BigQuery Data Transfer Service configurations: scheduled queries, and loads from Cloud Storage, Amazon S3, Azure Blob Storage, Google Ads and the other supported sources.

```yaml
transfers:
  daily_revenue:
    display_name: Daily revenue rollup
    data_source_id: scheduled_query
    destination_dataset_id: reporting        # a dataset key: the location is taken from it
    schedule: every day 02:00
    query_file: sql/daily_revenue.sql.tftpl
    params:
      destination_table_name_template: "daily_revenue_{run_date}"
      write_disposition: WRITE_TRUNCATE
```

Prerequisites: the BigQuery Data Transfer API (`bigquerydatatransfer.googleapis.com`) is enabled. The identity creating the transfer (or `service_account_name`) can run the query or read the source, and write the destination.

## Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `display_name` | string | map key | Name shown in the console. |
| `data_source_id` | string | | Required: `scheduled_query`, `google_cloud_storage`, `amazon_s3`, `azure_blob_storage`, `google_ads`, ... |
| `project_id` | string | [resolved](configuration.md#projects) | |
| `location` | string | see below | Must match the destination dataset. |
| `destination_dataset_id` | string | | A dataset key from this file (its real ID is used) or a dataset ID. Not needed for DML/DDL scheduled queries. |
| `schedule` | string | source default | e.g. `every 24 hours`, `every day 02:00`, `every monday 06:00`, `1st,3rd monday of month 09:00`. |
| `disabled` | bool | `false` | Create paused. |
| `schedule_options` | mapping | | `start_time`, `end_time` (RFC 3339), `disable_auto_scheduling` (runs only when triggered manually). |
| `data_refresh_window_days` | number | | Days of data re-ingested each run (sources that support it). |
| `notification_pubsub_topic` | string | | `projects/P/topics/T`, notified after each run. |
| `email_preferences` | mapping | | `enable_failure_email: true` emails the owner on failures. |
| `service_account_name` | string | | Run as this service account instead of the creator. |
| `query` | string | | Shortcut for `params.query`. |
| `query_file` | path | | Shortcut for `params.query`, read from a file; `*.tftpl` files are rendered. |
| `params` | map | | Source-specific parameters. Numbers and booleans are converted to strings. |
| `encryption_configuration` | `{kms_key_name}` | | |
| `sensitive_params` | `{secret_access_key_secret}` | | Name of the `secrets` entry holding the AWS secret access key. |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | |

At most one of `query`, `query_file` and `params.query` may be set.

**Location**, first one set wins: `location` → the location of `destination_dataset_id` when that dataset is in this file → `defaults.transfers.location` → `defaults.location` → US.

## Scheduled queries

```yaml
transfers:
  # Write query results to a new table per run.
  top_customers_weekly:
    data_source_id: scheduled_query
    destination_dataset_id: reporting
    schedule: every monday 06:00
    query: |
      SELECT customer_id, SUM(amount) AS revenue
      FROM `${project_id}.sales.orders`
      WHERE DATE(ordered_at) >= DATE_SUB(@run_date, INTERVAL 7 DAY)
      GROUP BY customer_id
    params:
      destination_table_name_template: "top_customers_{run_date}"
      write_disposition: WRITE_TRUNCATE       # or WRITE_APPEND
      partitioning_field: ""                  # optional: column-partitioned destination

  # DML or DDL: no destination dataset.
  refresh_ltv:
    data_source_id: scheduled_query
    location: US
    schedule: every 6 hours
    query: CALL `${project_id}.udfs.refresh_customer_ltv`()
```

`@run_time` and `@run_date` are query parameters filled in at run time, and `{run_date}` / `{run_time|"%Y%m%d"}` are table-name templates. None of them start with `$`, so they are unaffected by the module's templating.

## Cloud Storage loads

```yaml
transfers:
  partner_orders:
    data_source_id: google_cloud_storage
    destination_dataset_id: landing
    schedule: every 24 hours
    params:
      data_path_template: gs://partner-exports/orders/*.csv
      destination_table_name_template: partner_orders     # the table must exist
      file_format: CSV
      write_disposition: APPEND
      skip_leading_rows: 1
      max_bad_records: 0
      delete_source_files: false
```

Load transfers write into existing tables, so declare the destination table in the same file. The transfer is created after it.

## Amazon S3 loads

```yaml
transfers:
  marketplace_orders:
    data_source_id: amazon_s3
    destination_dataset_id: landing
    schedule: every 24 hours
    params:
      data_path: s3://marketplace-exports/orders/*.csv
      destination_table_name_template: marketplace_orders
      access_key_id: ${aws_access_key_id}
      file_format: CSV
      write_disposition: WRITE_APPEND
    sensitive_params:
      secret_access_key_secret: aws_secret_access_key     # module.secrets["aws_secret_access_key"]
```

## Ordering

Transfers are created after all datasets, tables, views, materialized views and routines of the configuration, because BigQuery validates scheduled queries when they are created.

Newly created transfers start on their schedule. Use `disabled: true`, or `schedule_options.start_time` in the future, to create them without running them yet.
