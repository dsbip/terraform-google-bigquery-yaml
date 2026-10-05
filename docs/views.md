# Views and materialized views

Views and materialized views are declared in the top-level `views` and `materialized_views` sections. Each names its dataset with `dataset:`, a key under `datasets`:

```yaml
datasets:
  reporting: {}

views:
  revenue_by_country:
    dataset: reporting
    description: Revenue per country.
    query: |
      SELECT country, SUM(amount) AS revenue
      FROM `${project_id}.sales.orders`
      GROUP BY country
  customers:
    dataset: reporting
    query_file: sql/customers.sql.tftpl

materialized_views:
  daily_revenue:
    dataset: reporting
    query: |
      SELECT DATE(ordered_at) AS day, SUM(amount) AS revenue
      FROM `${project_id}.sales.orders`
      GROUP BY day
    refresh_interval_ms: 1800000
```

## View keys

| Key | Type | Default | Description |
|---|---|---|---|
| `dataset` | string | required | Key of the view's dataset under `datasets`. |
| `table_id` | string | map key | View ID. |
| `query` | string | | GoogleSQL query. Exactly one of `query` / `query_file`. |
| `query_file` | path | | SQL file; `*.tftpl` files are template-rendered ([templating.md](templating.md)). |
| `use_legacy_sql` | bool | `false` | Use legacy SQL. |
| `friendly_name`, `description` | string | | |
| `labels` | map | | Merged with the default labels. |
| `expiration_time` | number | | Expiry time in milliseconds since the epoch. |
| `deletion_protection` | bool | `false` | Views hold no data, so the module does not protect them by default. |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | | Provider deletion policy. |
| `resource_tags` | map | | Resource Manager tags. |
| `iam` | list | | [IAM bindings](configuration.md#iam-bindings) on the view. |

Changing a view's query is an in-place update.

## Materialized view keys

| Key | Type | Default | Description |
|---|---|---|---|
| `dataset` | string | required | Key of the materialized view's dataset under `datasets`. |
| `table_id` | string | map key | Materialized view ID. |
| `query` / `query_file` | string / path | | Exactly one is required. |
| `enable_refresh` | bool | `true` (BigQuery) | Refresh automatically when base tables change. |
| `refresh_interval_ms` | number | 1800000 (BigQuery) | Maximum refresh frequency. |
| `allow_non_incremental_definition` | bool | | Allow queries that cannot refresh incrementally (requires `max_staleness`). |
| `max_staleness` | string | | INTERVAL literal, e.g. `"0-0 0 4:0:0"`. |
| `time_partitioning`, `range_partitioning`, `clustering` | | | As for [tables](tables.md#partitioning-and-clustering); partition on a base-table partitioning column. |
| `encryption_configuration` | `{kms_key_name}` | | |
| `friendly_name`, `description`, `labels`, `expiration_time`, `resource_tags` | | | As for views. |
| `deletion_protection` | bool | provider default (`true`) | A rebuild costs a full scan, so materialized views are protected like tables. |
| `deletion_policy` | | | |
| `iam` | list | | IAM bindings. |

## Creation order

BigQuery checks a view's query when the view is created, so everything it selects from must exist first. The module creates resources in this order:

1. datasets
2. tables
3. materialized views (they read tables)
4. routines (UDFs and table functions may read tables and materialized views)
5. views (may read tables, materialized views and call routines)
6. authorized views, datasets and routines
7. transfers

So views may use tables, materialized views and UDFs from the same configuration in any dataset.

## Views on views

Views inside one configuration are created in parallel, so a view that selects from **another view in the same configuration** may be created first and rejected by BigQuery (`Not found: Table ...`).

Put each layer in its own YAML file and module call, chained with `depends_on`:

```hcl
module "base" {
  source      = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v2.0.0"
  project_id  = var.project_id
  config_file = "${path.module}/base.yaml"      # tables and first-level views
}

module "marts" {
  source      = "github.com/dsbip/terraform-google-bigquery-yaml?ref=v2.0.0"
  project_id  = var.project_id
  config_file = "${path.module}/marts.yaml"     # views over base views
  depends_on  = [module.base]
}
```

The second file declares datasets from the first with `create: false` when its views or authorizations need them. See the [layered-views example](../examples/layered-views).

## SQL files

Keep each view's SQL in its own file and reference it with `query_file`, relative to the configuration file. Materialized views work the same way:

```yaml
views:
  revenue_by_country:
    dataset: reporting
    query_file: sql/revenue_by_country.sql.tftpl
```

```sql
-- sql/revenue_by_country.sql.tftpl
SELECT c.country, SUM(o.amount) AS revenue
FROM `${project_id}.${datasets.sales}.orders` AS o
JOIN `${project_id}.${datasets.sales}.customers` AS c USING (customer_id)
GROUP BY c.country
```

- **`.sql.tftpl`** files are rendered with `templatefile()`: `${project_id}`, `${datasets.<key>}` (the dataset's real ID, which follows `dataset_id` overrides) and every `template_vars` entry are available. Write `$${` for a literal `${`.
- **`.sql`** files are sent to BigQuery exactly as written.
- The file holds **only the query** (`SELECT ...` or `WITH ...`), not a `CREATE OR REPLACE VIEW ... AS` statement. The module creates the view through the BigQuery API from the YAML (the dataset, the key or `table_id`, `description`, `labels`), and BigQuery takes only the query. If you are moving DDL files over, delete everything up to and including `AS`. A file that starts with `CREATE` fails the plan. Comments and a `#standardSQL` line before the query are fine.
- The plan fails if a `.sql` file uses `${project_id}`, `${datasets...}` or a `template_vars` name, which only a `.tftpl` file would have replaced; rename the file to `.sql.tftpl`. Other `${...}` text, for example in a string literal, is left alone.
- The plan also fails for an empty file or an empty `query`.

## SQL tips

- Refer to tables with fully qualified names (`` `project.dataset.table` ``). With templating, write `` `${project_id}.sales.orders` `` in the YAML, or `` `${project_id}.${datasets.sales}.orders` `` in a `.tftpl` file so dataset ID overrides are followed.
- Use YAML block scalars (`query: |`) for multi-line SQL; no escaping is needed.
- A `query_file` that is not a `.tftpl` file is sent verbatim, including any `${...}` it contains.
