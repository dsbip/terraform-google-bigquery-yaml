# Upgrading from v1 to v2

v2 changes one thing about the configuration file: tables, views, materialized views and routines are no longer nested inside their dataset. They are top-level sections, and each entry names its dataset with `dataset:`.

Everything else is unchanged: the keys and settings of every resource, defaults, references, Terraform addresses and outputs. Upgrading needs no state changes, and the first plan after the upgrade shows no changes.

## Before and after

v1:

```yaml
datasets:
  sales:
    description: Orders and customers.
    tables:
      orders:
        schema_file: schemas/orders.json
    views:
      revenue:
        query: SELECT SUM(amount) AS revenue FROM `${project_id}.sales.orders`
```

v2:

```yaml
datasets:
  sales:
    description: Orders and customers.

tables:
  orders:
    dataset: sales
    schema_file: schemas/orders.json

views:
  revenue:
    dataset: sales
    query: SELECT SUM(amount) AS revenue FROM `${project_id}.sales.orders`
```

## Steps

1. **Update the module version** to `ref=v2.0.0` and run `terraform init -upgrade`. If your YAML files start with a schema line, point it at v2.0.0 too:

   ```yaml
   # yaml-language-server: $schema=https://raw.githubusercontent.com/dsbip/terraform-google-bigquery-yaml/v2.0.0/schemas/bigquery-config.schema.json
   ```

2. **Rewrite the YAML files.** `scripts/upgrade-to-v2.py` does it for you. It needs Python 3.8 or newer and no packages. After `terraform init`, a copy is in `.terraform/modules/<module name>/scripts/`; or download it:

   ```sh
   curl -O https://raw.githubusercontent.com/dsbip/terraform-google-bigquery-yaml/v2.0.0/scripts/upgrade-to-v2.py
   python upgrade-to-v2.py --check path/to/*.yaml   # list files that need upgrading
   python upgrade-to-v2.py path/to/*.yaml           # rewrite them in place
   ```

   It keeps comments, flow-style mappings and `${...}` placeholders, and it never changes a key. Use `--stdout` to see the result without writing it. If it cannot rewrite a file safely, it leaves the file unchanged and says why; see [Cases to handle by hand](#cases-to-handle-by-hand).

   To do it by hand instead: move every entry from `datasets.<d>.tables` to a top-level `tables` section, add `dataset: <d>` to it, and do the same for `views`, `materialized_views` and `routines`.

3. **Run `terraform plan`.** It should show no changes. A v1 file that was not upgraded fails with a message for each nested section, for example:

   ```
   datasets.sales.tables: tables are not nested in datasets; move each entry to the top-level tables section and add dataset: sales to it (see docs/upgrading.md)
   ```

## Why the plan shows no changes

Tables, views, materialized views and routines are still addressed by `"<dataset key>.<key>"`. `datasets.sales.tables.orders` in v1 and `tables.orders` with `dataset: sales` in v2 are both `google_bigquery_table.table["sales.orders"]`, with the same BigQuery IDs. The outputs keep the same keys too.

Before v2.0.0 was released, every example and the live-test fixture was planned in its v1 and its v2 form with the real Google provider. All 174 planned resources were identical: addresses, actions and every attribute.

## Cases to handle by hand

**The same key in two datasets.** v1 keys only had to be unique within a dataset, so `raw` and `staging` could both contain a table keyed `orders`. In v2, keys are unique within the `tables` section. The script stops and names such keys. Rename all but one, keep the BigQuery ID with `table_id` (`routine_id` for routines), and tell Terraform about the new address with a `moved` block in your root module:

```yaml
tables:
  orders:
    dataset: raw
  staging_orders:
    dataset: staging
    table_id: orders
```

```hcl
moved {
  from = module.bigquery.google_bigquery_table.table["staging.orders"]
  to   = module.bigquery.google_bigquery_table.table["staging.staging_orders"]
}
```

Use `google_bigquery_table.view[...]`, `.materialized_view[...]` or `google_bigquery_routine.this[...]` for the other kinds. If the entry has `iam` bindings, move each `google_bigquery_table_iam_member.this["<old address>|<role>|<member>"]` (or `google_bigquery_routine_iam_member`) the same way; `terraform state list` shows them.

Do not just write the second `orders:` under `tables`: YAML keeps only the last of two equal keys. The module detects duplicate keys and fails the plan rather than dropping one, but the fix is the same.

**Flow style.** A dataset or a section written on one line with children inside, such as `sales: { tables: { orders: {} } }`, is not rewritten. Convert it to block style first, or move the entries by hand.

**Configurations built in HCL.** If you pass `config_yaml = yamlencode({...})`, move the `tables`, `views`, `materialized_views` and `routines` maps to the top level of the object and add `dataset = "<key>"` to each entry.

## Other changes in v2

- References to tables, views, materialized views and routines may use the key alone: `authorized_views: [revenue]`, `referenced_table: customers`. The v1 forms (`sales.revenue`, `project.dataset.view`) still work. See [configuration.md](configuration.md#references).
- Validation messages use the new paths: `tables.orders.schema_file: ...` instead of `datasets.sales.tables.orders.schema_file: ...`.
- Keys of datasets, tables, views, materialized views and routines cannot contain `.`.
- `dataset` cannot be set in `defaults`.
- Duplicate keys and tab indentation are reported with line numbers instead of being dropped silently or failing with a parser error.

See the [changelog](../CHANGELOG.md) for the full list.
