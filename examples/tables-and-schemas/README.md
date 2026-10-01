# Tables and schemas

Every way of defining a table:

| Table | Shows |
|---|---|
| `events.page_views` | Schema from a JSON file with nested (`RECORD`) and repeated fields; hourly partitions on a column with expiration; required partition filter; clustering |
| `events.sessions` | Schema from a YAML file; ingestion-time daily partitioning |
| `events.customer_scores` | Integer-range partitioning |
| `events.users`, `events.purchases` | Primary key, and a foreign key from `purchases` to `users` referenced by its key (`users`) |
| `events.backfill_scratch` | A table that expires on a fixed date |
| `landing.daily_orders_csv` | External CSV table with an explicit schema and CSV options |
| `landing.clickstream_parquet` | External hive-partitioned Parquet with schema autodetection |
| `landing.webhooks_json` | External gzipped newline-delimited JSON with a schema file |

The `events` dataset also sets `default_partition_expiration_ms`, `max_time_travel_hours` and `storage_billing_model`.

## Run

```bash
terraform init
terraform apply -var project_id=my-project -var landing_bucket=my-landing-bucket
```

The external tables read `gs://<landing_bucket>/orders/`, `/clickstream/` and `/webhooks/`. BigQuery needs files there to autodetect the Parquet schema when it creates `clickstream_parquet`; the other tables can be created before any files exist.

## Files

| File | Contents |
|---|---|
| `config.yaml` | The configuration |
| `schemas/page_views.json` | JSON schema with a RECORD and a REPEATED field |
| `schemas/sessions.yaml` | YAML schema |
| `schemas/webhooks.json` | Schema of the external JSON table |
