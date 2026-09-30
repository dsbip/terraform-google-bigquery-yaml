# Connections

BigQuery connections hold the identity or credentials that BigQuery uses to reach other systems. They are top-level entries:

```yaml
connections:
  lake:
    friendly_name: Data lake
    location: US
    cloud_resource: {}
    iam:
      - role: roles/bigquery.connectionUser
        members: [group:analysts@example.com]
```

A connection's **type** is the one type key it contains. The key alone is enough for types without settings (`cloud_resource:` or `cloud_resource: {}`). Validation rejects entries with no type or several types.

## Common keys

| Key | Type | Default | Description |
|---|---|---|---|
| `connection_id` | string | map key | Connection ID. |
| `project_id` | string | [resolved](configuration.md#projects) | |
| `location` | string | [resolved](configuration.md#locations) | Must match the resources it reaches (e.g. the Cloud SQL region, or `aws-us-east-1`). |
| `friendly_name`, `description` | string | | |
| `kms_key_name` | string | | Cloud KMS key to encrypt the connection's credentials. |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | |
| `iam` | list | | [IAM bindings](configuration.md#iam-bindings); users of a connection need `roles/bigquery.connectionUser`. |

## Types

| Type key | Used for | Settings |
|---|---|---|
| `cloud_resource` | BigLake and object tables, BigLake Iceberg tables, remote functions, Vertex AI models | none |
| `cloud_sql` | Federated queries (`EXTERNAL_QUERY`) against Cloud SQL | `instance_id` (`project:region:instance`), `database`, `type` (`POSTGRES`, `MYSQL`), `credential: {username, password_secret}` |
| `cloud_spanner` | Federated queries against Spanner | `database` (`projects/P/instances/I/databases/D`), `database_role`, `use_parallelism`, `use_data_boost`, `max_parallelism` |
| `aws` | BigQuery Omni on Amazon S3 | `access_role: {iam_role_id}` |
| `azure` | BigQuery Omni on Azure Blob Storage | `customer_tenant_id`, `federated_application_client_id` |
| `spark` | Stored procedures for Apache Spark | optional `metastore_service_config: {metastore_service}`, `spark_history_server_config: {dataproc_cluster}` |
| `configuration` | BigQuery connector framework (AlloyDB and other connectors) | `connector_id`, `asset: {database, google_cloud_resource}`, `authentication: {username_password: {username, password_secret}}`, `endpoint: {host_port}`, `network: {private_service_connect: {network_attachment}}` |

Passwords are never written in the YAML: `password_secret` names an entry of the module's `secrets` variable ([secrets](configuration.md#secrets)).

```yaml
connections:
  orders_db:
    location: us-central1
    cloud_sql:
      instance_id: my-project:us-central1:orders-db
      database: orders
      type: POSTGRES
      credential:
        username: bq_reader
        password_secret: orders_db_password     # module.secrets["orders_db_password"]

  catalog:
    configuration:
      connector_id: google-alloydb
      asset:
        database: inventory
        google_cloud_resource: //alloydb.googleapis.com/projects/p/locations/us-central1/clusters/c/instances/i
      authentication:
        username_password:
          username: bq
          password_secret: alloydb_password
```

## Using a connection

Other entries reference a connection by its key. The module substitutes the connection's full name and creates the connection first:

| Entry | Key |
|---|---|
| External (BigLake) table | `external_data_configuration.connection_id` |
| BigLake managed table | `biglake_configuration.connection_id` |
| Remote function | `remote_function_options.connection` |
| Spark procedure | `spark_options.connection` |
| External dataset (e.g. AWS Glue) | `external_dataset_reference.connection` |

Connections not managed by this configuration are referenced by full ID: `project.location.connection_id` or `projects/P/locations/L/connections/C`. A bare name that is not a key in the file is reported as an error.

## Granting access to the connection

`cloud_resource`, `spark`, `cloud_sql` and connector connections get a Google-managed service account when created. The `connections` output exposes it as `service_account_id`, and the AWS/Azure identity as `identity`. Grant it access to what the connection reaches:

```hcl
resource "google_storage_bucket_iam_member" "lake_reader" {
  bucket = "my-data-lake"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.bigquery.connections["lake"].service_account_id}"
}
```

| Connection used for | Grant its service account |
|---|---|
| BigLake / object tables | `roles/storage.objectViewer` on the bucket |
| BigLake Iceberg tables | `roles/storage.objectAdmin` on the storage location |
| Remote functions | `roles/run.invoker` on the Cloud Run service |
| Cloud SQL | `roles/cloudsql.client` |
| Spanner (Data Boost) | `roles/spanner.databaseReader` |

For AWS and Azure, configure the external role or application to trust `identity` (see the BigQuery Omni documentation).
