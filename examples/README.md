# Examples

Each directory is a runnable Terraform root module: a `main.tf` that calls the module and a commented `config.yaml` (plus SQL, JavaScript or schema files where needed).

| Example | Scenario | Resources |
|---|---|---|
| [basic](basic) | One dataset with two tables, a view and an access grant | 6 |
| [tables-and-schemas](tables-and-schemas) | Schema files (JSON and YAML), hourly/daily/ingestion-time/range partitioning, clustering, primary and foreign keys, expiring tables, external CSV/Parquet/JSON tables | 12 |
| [authorized-views](authorized-views) | Sharing HR data through authorized views, an authorized dataset and an authorized table function | 16 |
| [routines](routines) | SQL and JavaScript UDFs, ARRAY/STRUCT types, a table function, a procedure from a template file, a masking function, a remote function | 15 |
| [scheduled-queries](scheduled-queries) | Scheduled queries (snapshot, MERGE, paused with a time window), Cloud Storage and Amazon S3 loads with a secret | 12 |
| [connections](connections) | Cloud resource, Cloud SQL, Spanner, AWS, Azure and Spark connections; BigLake, object and Iceberg tables; a Spark procedure | 14 |
| [multi-environment](multi-environment) | One templated YAML deployed to dev and prod with different protection and retention | 14 |
| [existing-datasets](existing-datasets) | Adding tables, grants and authorizations to datasets created elsewhere, including another project | 8 |
| [layered-views](layered-views) | Views on views across two YAML files and module calls | 10 |
| [complete](complete) | A shop analytics platform that uses every feature | 37 |

The resource counts include the module's `terraform_data.validation`. They are checked in CI by `tests/examples.tftest.hcl` (mocked) and by `tests/python/test_example_plans.py` (real provider).

## Running an example

```bash
cd examples/basic
terraform init
terraform plan -var project_id=my-project
terraform apply -var project_id=my-project
terraform destroy -var project_id=my-project
```

Examples reference the module as `source = "../.."`. In your own code, use the GitHub source with a version tag:

```hcl
source = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v1.0.0"
```

Examples meant to be destroyed set `deletion_protection: false` for tables and `delete_contents_on_destroy: true` for datasets. Production configurations should keep the protective defaults.

Some examples refer to things that must exist before `apply` succeeds, for example buckets, Cloud SQL instances, Cloud Run services or AWS roles. They plan without them; each example's README lists what it needs.
