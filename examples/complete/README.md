# Complete

An analytics platform for an online shop, using every feature of the module in one configuration (37 resources).

| Part | Contents |
|---|---|
| Defaults | EU location; a platform label; 7-day time travel; an `OWNER` grant for the platform team on every dataset; failure emails for all transfers |
| Connections | `lake` (BigLake) and `remote` (remote functions, with `connectionUser` for analysts) |
| `raw` | `orders` (schema file, ingestion-time partitioning), `customers`, and `clickstream`, a BigLake table over Parquet in the lake with metadata caching |
| `core` | `dim_customer` and `fct_orders` with primary and foreign keys, partitioning and clustering; `mv_daily_sales` materialized view; authorizes `reporting` (dataset), `partner_share.partner_daily_sales` (view) and `udfs.customer_orders` (routine) |
| `udfs` | `normalize_email`, masking function `mask_email`, table function `customer_orders`, procedure `rebuild_dim_customer`, remote function `review_sentiment` |
| `reporting` | `customer_360` (SQL template using a UDF) and `sales_by_country` (reads the materialized view); analysts can read it |
| `partner_share` | `partner_daily_sales`, shared with a partner's service account through table IAM |
| Transfers | Hourly Cloud Storage load into `raw.orders`, nightly `CALL` of the rebuild procedure, weekly top-customers snapshot |

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var lake_bucket=my-shop-lake \
  -var platform_team_group=data-platform@your-domain.com \
  -var analysts_group=analysts@your-domain.com \
  -var partner_service_account=partner@partner-project.iam.gserviceaccount.com \
  -var sentiment_service_url=https://review-sentiment-xyz-ew.a.run.app
```

Prerequisites:

- The BigQuery Connection and Data Transfer APIs are enabled.
- The groups and the partner service account exist.
- The lake bucket holds the clickstream Parquet files and the order exports.
- A Cloud Run service backs the sentiment function.

After apply, grant the connection service accounts from the `connections` output access to the bucket and the Cloud Run service.

The files that make it up:

| File | Contents |
|---|---|
| `config.yaml` | The configuration |
| `schemas/*.json` | Table schemas, one file per table (`schema_file`) |
| `sql/customer_360.sql.tftpl`, `sql/sales_by_country.sql.tftpl`, `sql/partner_daily_sales.sql.tftpl` | View SQL (`query_file`) |
| `sql/mv_daily_sales.sql.tftpl` | Materialized view SQL |
| `routines/*.sql`, `routines/*.sql.tftpl` | Routine bodies, one file per routine (`definition_file`) |
