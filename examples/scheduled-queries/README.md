# Scheduled queries and data transfers

| Transfer | Source | Shows |
|---|---|---|
| `daily_revenue` | scheduled query | SQL from a `.tftpl` file; one snapshot table per run date; location taken from the destination dataset |
| `refresh_customer_ltv` | scheduled query | A `MERGE` statement with no destination dataset |
| `black_friday_hourly` | scheduled query | Created paused, with a start and end time |
| `partner_orders_gcs` | Cloud Storage | Loads CSV files into an existing table |
| `marketplace_orders_s3` | Amazon S3 | The AWS secret key passed through the module's `secrets` variable |

`defaults.transfers` turns on failure emails for all of them. The `shop` and `reporting` datasets and the load destination tables are declared in the same file; transfers are created after them.

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var partner_bucket=my-partner-bucket \
  -var aws_access_key_id=AKIA... \
  -var aws_secret_access_key=...
```

Prerequisites:

- The BigQuery Data Transfer API is enabled.
- The Cloud Storage load needs read access to the partner bucket.
- The S3 load needs valid AWS credentials. Leave `marketplace_orders_s3` out of `config.yaml` if you have none.

`aws_secret_access_key` is a sensitive variable; the YAML only names the secret (`secret_access_key_secret: aws_secret_access_key`).

After apply, the transfers run on their schedule. Trigger a run from the BigQuery console (Scheduled queries / Data transfers), or pause them by setting `disabled: true`.
