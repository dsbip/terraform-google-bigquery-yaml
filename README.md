# terraform-google-bigquery-yaml

[![CI](https://github.com/dsbip/terraform-google-bigquery-yaml/actions/workflows/ci.yml/badge.svg)](https://github.com/dsbip/terraform-google-bigquery-yaml/actions/workflows/ci.yml)

A Terraform module that creates BigQuery resources from a YAML configuration file:

- **datasets**, with access grants
- **tables**: native, partitioned, clustered, with keys, external (Cloud Storage, Sheets, Bigtable) and BigLake
- **views** and **materialized views**
- **authorized views, authorized datasets and authorized routines**
- **routines**: SQL and JavaScript UDFs, table-valued functions, stored procedures, remote functions, Spark procedures
- **connections**: Cloud resource, Cloud SQL, Spanner, AWS, Azure, Spark, connector framework (AlloyDB, ...)
- **data transfers**: scheduled queries, Cloud Storage, Amazon S3 and other Data Transfer Service sources
- **IAM** on tables, views, routines and connections

Describing a platform takes one readable file instead of hundreds of lines of HCL, and the module catches mistakes before anything reaches BigQuery. A misspelled key fails the plan with its YAML path and a suggestion, for example `datasets.sales: unknown key "descripton" (did you mean description?)`.

```yaml
# config.yaml
defaults:
  location: EU

datasets:
  sales:
    description: Orders from the web shop.
    access:
      - role: READER
        members: [group:analysts@example.com]
    authorized_views: [revenue_by_day]   # the view below may read sales

  reporting: {}

tables:
  orders:
    dataset: sales
    schema_file: schemas/orders.json
    time_partitioning: { field: ordered_at }
    clustering: [customer_id]

views:
  revenue_by_day:
    dataset: reporting
    query_file: sql/revenue_by_day.sql.tftpl
```

```sql
-- sql/revenue_by_day.sql.tftpl
SELECT DATE(ordered_at) AS day, SUM(amount) AS revenue
FROM `${project_id}.sales.orders`
GROUP BY day
```

Datasets, tables, views, materialized views and routines are separate top-level sections. A table, view or routine is not indented under its dataset; it names it with `dataset: <key>`. Table schemas live in JSON files (`schema_file`) and view SQL in SQL files (`query_file`), next to the YAML; inline `schema:` and `query:` work too.

```hcl
module "bigquery" {
  source = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v2.0.0"

  project_id  = "my-project"
  config_file = "${path.module}/config.yaml"
}
```

Upgrading from v1, where tables and views were nested inside their dataset? See [docs/upgrading.md](docs/upgrading.md); no state changes are needed.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Usage](#usage)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Examples](#examples)
- [Documentation](#documentation)
- [Testing](#testing)
- [Limitations](#limitations)
- [Upgrading from v1](docs/upgrading.md)

## Features

| YAML | Creates | Guide |
|---|---|---|
| `datasets.<key>` | `google_bigquery_dataset` | [datasets.md](docs/datasets.md) |
| `datasets.<key>.access` | `google_bigquery_dataset_access` (non-authoritative grants) | [datasets.md](docs/datasets.md#access-grants) |
| `tables.<key>` | `google_bigquery_table` | [tables.md](docs/tables.md) |
| `views.<key>` / `materialized_views.<key>` | `google_bigquery_table` (view / materialized view) | [views.md](docs/views.md) |
| `datasets.<key>.authorized_views` / `_datasets` / `_routines` | `google_bigquery_dataset_access` | [authorized-views.md](docs/authorized-views.md) |
| `routines.<key>` | `google_bigquery_routine` | [routines.md](docs/routines.md) |
| `connections.<key>` | `google_bigquery_connection` | [connections.md](docs/connections.md) |
| `transfers.<key>` | `google_bigquery_data_transfer_config` | [transfers.md](docs/transfers.md) |
| `iam:` on tables, views, routines, connections | `google_bigquery_*_iam_member` | [configuration.md](docs/configuration.md#iam-bindings) |

Every entry under `tables`, `views`, `materialized_views` and `routines` has a `dataset:` key naming its dataset under `datasets`, and takes the dataset's project and dataset ID from it.

Across the whole configuration:

- **Defaults** for every resource type (`defaults.tables.deletion_protection`, `defaults.location`, ...), with labels merged at every level.
- **References by key.** `dataset: sales`, `connection_id: lake`, `referenced_table: customers`, `authorized_views: [revenue_by_day]` and `destination_dataset_id: reporting` resolve to real IDs, even when you override them.
- **Templating.** `config_file` is rendered with `templatefile()`, so one YAML serves every environment. SQL files ending in `.tftpl` are rendered too ([templating.md](docs/templating.md)).
- **Validation before anything is planned.** Unknown keys (with suggestions), wrong shapes, missing files, unresolvable references and more are all reported together, each with its YAML path ([validation.md](docs/validation.md)).
- **A JSON Schema** ([schemas/bigquery-config.schema.json](schemas/bigquery-config.schema.json)) for autocompletion and inline errors in VS Code and JetBrains IDEs.
- **Secrets stay out of YAML.** Passwords and keys are passed in the `secrets` variable and referenced by name.
- **Safe ordering.** Terraform creates tables, then materialized views, then routines, then views, then authorizations, then transfers, so BigQuery's creation-time query validation succeeds.

## Requirements

| Tool | Version |
|---|---|
| Terraform | >= 1.5 (the unit tests need >= 1.7) |
| `hashicorp/google` provider | >= 7.42, < 9.0 |

APIs used by the resources you configure: `bigquery.googleapis.com`, and `bigqueryconnection.googleapis.com` for connections, `bigquerydatatransfer.googleapis.com` for transfers.

The identity running Terraform needs `roles/bigquery.admin` (or narrower roles covering the resources in your file), plus `roles/bigquery.connectionAdmin` for connections. For transfers that run as a service account (`service_account_name`), it also needs `roles/iam.serviceAccountUser` on that account.

## Usage

```hcl
module "bigquery" {
  source = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v2.0.0"

  project_id  = var.project_id                  # default project for everything in the file
  config_file = "${path.module}/bigquery.yaml"  # rendered with templatefile()

  template_vars = {                             # optional: ${env} etc. in the YAML
    env = "prod"
  }

  labels = {                                    # optional: added to every dataset/table/view
    managed_by = "terraform"
  }

  secrets = {                                   # optional: referenced by name from the YAML
    orders_db_password = var.orders_db_password
  }
}
```

To get IDE autocompletion and validation, put this line at the top of the YAML file (the VS Code YAML extension and JetBrains IDEs understand it):

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/dsbip/terraform-google-bigquery-yaml/v2.0.0/schemas/bigquery-config.schema.json
```

For larger estates, call the module once per domain or per layer: one YAML file each, chained with `depends_on` where one layer reads another ([layered-views example](examples/layered-views)).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `config_file` | `string` | `null` | Path to the YAML file. Rendered with `templatefile()` before parsing; `${project_id}` and `template_vars` are available. Exactly one of `config_file` / `config_yaml`. |
| `config_yaml` | `string` | `null` | YAML content as a string (e.g. `yamlencode({...})`). Used verbatim. |
| `template_vars` | `any` (map) | `{}` | Values for `${...}` placeholders in `config_file` and in `*.tftpl` files. Must be known at plan time. |
| `project_id` | `string` | `null` | Default project. The YAML top-level `project_id` wins over it; resource-level `project_id` wins over both. |
| `labels` | `map(string)` | `{}` | Labels added to every dataset, table, view and materialized view. YAML labels with the same key win. |
| `secrets` | `map(string)` (sensitive) | `{}` | Values referenced by name from the YAML: `password_secret`, `secret_access_key_secret`. |
| `base_path` | `string` | `null` | Directory for relative paths in the YAML. Defaults to the directory of `config_file`, or `path.root` with `config_yaml`. |

## Outputs

| Name | Description |
|---|---|
| `project_id` | The resolved default project. |
| `datasets` | Created datasets by key: `id`, `project`, `dataset_id`, `location`, `self_link`. |
| `tables` | Tables by `"<dataset key>.<table key>"` (e.g. `"sales.orders"` for `tables.orders` with `dataset: sales`): `id`, `project`, `dataset_id`, `table_id`, `self_link`. |
| `views` | Views, same shape as `tables`. |
| `materialized_views` | Materialized views, same shape as `tables`. |
| `routines` | Routines by `"<dataset key>.<routine key>"`: `id`, `project`, `dataset_id`, `routine_id`, `routine_type`. |
| `connections` | Connections by key: `id`, `name`, `project`, `location`, `connection_id`, `service_account_id` (the Google-managed identity to grant access to), `identity` (AWS/Azure). |
| `transfers` | Transfer configs by key: `id`, `name`, `display_name`, `data_source_id`, `location`. |
| `dataset_access` | Access grants by `"<dataset key>\|<role>\|<member>"`. |
| `authorized_views` / `authorized_datasets` / `authorized_routines` | Authorization entries by `"<dataset key>\|<target>"`. |
| `resource_counts` | Number of resources of each kind. |

## Examples

Each example is a runnable root module with a commented `config.yaml`; see [examples/README.md](examples/README.md).

| Example | Shows |
|---|---|
| [basic](examples/basic) | One dataset, two tables, a view, an access grant |
| [tables-and-schemas](examples/tables-and-schemas) | Schema files (JSON/YAML), time/range partitioning, clustering, keys, external tables |
| [authorized-views](examples/authorized-views) | Sharing sensitive data through authorized views, datasets and routines |
| [routines](examples/routines) | SQL/JS UDFs, table functions, procedures, data masking, remote functions |
| [scheduled-queries](examples/scheduled-queries) | Scheduled queries, Cloud Storage and S3 loads, secrets |
| [connections](examples/connections) | Every connection type, BigLake, object and Iceberg tables, Spark procedures |
| [multi-environment](examples/multi-environment) | One templated YAML deployed to dev and prod |
| [existing-datasets](examples/existing-datasets) | Managing tables, grants and authorizations in datasets created elsewhere |
| [layered-views](examples/layered-views) | Views on views, and chaining several configuration files |
| [complete](examples/complete) | An analytics platform using every feature |

## Documentation

| Guide | Contents |
|---|---|
| [configuration.md](docs/configuration.md) | File layout, keys and IDs, defaults and precedence, references, files, secrets, IAM |
| [datasets.md](docs/datasets.md) | Dataset settings, access grants, existing datasets |
| [tables.md](docs/tables.md) | Schemas, partitioning, clustering, constraints, external and BigLake tables |
| [views.md](docs/views.md) | Views, materialized views, views on views |
| [authorized-views.md](docs/authorized-views.md) | Authorized views, datasets and routines |
| [routines.md](docs/routines.md) | UDFs, table functions, procedures, data types |
| [connections.md](docs/connections.md) | Connection types and the resources that use them |
| [transfers.md](docs/transfers.md) | Scheduled queries and data transfers |
| [templating.md](docs/templating.md) | Placeholders, `*.tftpl` files, multiple environments |
| [validation.md](docs/validation.md) | What is checked, and how errors look |
| [design.md](docs/design.md) | How the module works, resource ordering, decisions |
| [testing.md](docs/testing.md) | Test layers and how to run them, including the live test |
| [troubleshooting.md](docs/troubleshooting.md) | Common errors and YAML pitfalls |
| [upgrading.md](docs/upgrading.md) | Moving a v1 configuration to the v2 layout |

## Testing

The module has four test layers, run by CI on every push:

1. `terraform fmt` and `terraform validate`
2. **98 unit tests** (`terraform test`, mocked provider): every feature, precedence rule and validation message, on Terraform 1.7 and latest with provider 7.42 and latest
3. **Real-provider plans** of all ten examples and the live-test fixture, without Google Cloud access, on Terraform 1.5.7 with provider 7.42.0 and on the latest versions; plus JSON Schema checks
4. **A live test** that deploys into a real project, checks that a second plan is empty, updates in place and destroys everything (run on demand)

See [docs/testing.md](docs/testing.md).

## Limitations

- Views that select from other views in the **same** configuration can be created in any order, and BigQuery rejects a view whose source does not exist yet. Put dependent views in a second module call with `depends_on` ([layered-views example](examples/layered-views)).
- Terraform creates all tables of a configuration in parallel. BigQuery keys are informational and unenforced, but if your project rejects a foreign key to a table created in the same apply, create the referenced table first (another module call, or run apply again).
- A few rarely used provider arguments are not exposed: `table_replication_info`, `schema_foreign_type_info`, `external_catalog_table_options`, `table_metadata_view`. Data policies and row access policies are not managed.
- Do not manage the same datasets with `google_bigquery_dataset_iam_*` resources or authoritative `access` blocks elsewhere; they would overwrite the grants and authorizations made here ([datasets.md](docs/datasets.md#access-grants)).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CHANGELOG.md](CHANGELOG.md). Licensed under the [Apache License 2.0](LICENSE).
