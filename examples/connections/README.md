# Connections

| Connection | Type | Used by |
|---|---|---|
| `lake` | `cloud_resource` | BigLake Parquet table `sales_biglake`, object table `product_images`, BigLake Iceberg table `events_iceberg`; `connectionUser` granted to analysts |
| `orders_db` | `cloud_sql` (PostgreSQL) | `EXTERNAL_QUERY` federated queries; password from the `secrets` variable |
| `catalog_spanner` | `cloud_spanner` | Federated queries with Data Boost |
| `aws_lake` | `aws` | BigQuery Omni on S3 (`aws-us-east-1`) |
| `azure_lake` | `azure` | BigQuery Omni on Azure (`azure-eastus2`) |
| `spark` | `spark` | The PySpark stored procedure `compact_small_files` |

Tables and the procedure refer to connections by key (`connection_id: lake`, `connection: spark`). `main.tf` shows how to use the `connections` output: it grants the lake connection's service account read access to the bucket.

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var lake_bucket=my-data-lake \
  -var orders_db_password=...
```

This example is a catalogue; applying all of it needs every external system:

- The BigQuery Connection API enabled.
- The `my-data-lake` bucket with the referenced files.
- A Cloud SQL instance `orders-db` in `us-central1`.
- A Spanner database `catalog/products`.
- An AWS IAM role and an Azure application trusting the connection identities.

Remove the entries you do not need. It plans without any of them.

After apply, the connection identities are in the `connections` output (`service_account_id` for Google Cloud connections, `identity` for AWS and Azure).
