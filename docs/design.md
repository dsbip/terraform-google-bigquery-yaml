# Design

This page explains how the module turns YAML into resources and why it is built this way. Read it before changing the module.

## Source layout

| File | Contents |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `variables.tf` | Inputs |
| `main.tf` | Loading and rendering the YAML, defaults, linking tables, views, materialized views and routines to their datasets, referenced files |
| `datasets.tf` | Datasets, access grants, authorized views/datasets/routines |
| `tables.tf` | Tables, materialized views, views, table IAM |
| `routines.tf` | Routines, data type conversion, routine IAM |
| `connections.tf` | Connections, connection IAM |
| `transfers.tf` | Data transfer configs |
| `validation.tf` | All checks and the precondition that reports them |
| `outputs.tf` | Outputs |
| `schemas/bigquery-config.schema.json` | The configuration format (read by `validation.tf` and by editors) |

## From YAML to resources

```
config_file ──templatefile()──▶ YAML text ──yamldecode()──▶ objects
                                                                │
          ┌─────────────────────────────────────────────────────┘
          ▼
   normalise (main.tf and one file per type)
     • drop explicit nulls, merge builtin < YAML defaults < resource
     • key tables, views, materialized views and routines by "<dataset key>.<key>"
     • fixed-shape objects: every attribute present, nested blocks as 0/1-element lists
     • resolve references, read referenced files, convert data types
          │
          ├──▶ validate (validation.tf) ──▶ local.validation_errors
          │                                     │
          ▼                                     ▼
   resources: for_each = { ... if local.config_valid }   terraform_data.validation
                                                          (precondition lists all errors)
```

Normalisation never fails on bad input: every lookup is wrapped in `try()` with a safe fallback. Bad input therefore reaches validation, which reports it by YAML path, instead of stopping the plan with a Terraform error pointing at module internals. Two kinds of errors are deliberately not caught, because Terraform's own message is better: YAML syntax errors and template rendering errors. Both show the file, line and column.

## Resources and ordering

| Kind | Resource | for_each key |
|---|---|---|
| dataset | `google_bigquery_dataset.this` | `<dataset>` |
| table | `google_bigquery_table.table` | `<dataset>.<table>` |
| materialized view | `google_bigquery_table.materialized_view` | `<dataset>.<view>` |
| view | `google_bigquery_table.view` | `<dataset>.<view>` |
| routine | `google_bigquery_routine.this` | `<dataset>.<routine>` |
| connection | `google_bigquery_connection.this` | `<connection>` |
| transfer | `google_bigquery_data_transfer_config.this` | `<transfer>` |
| access grant | `google_bigquery_dataset_access.access` | `<dataset>\|<role>\|<member>` |
| authorization | `google_bigquery_dataset_access.authorized_view` / `authorized_dataset` / `authorized_routine` | `<dataset>\|<target>` |
| IAM | `google_bigquery_{table,routine,connection}_iam_member.this` | `<resource key>\|<role>\|<member>` |
| validation | `terraform_data.validation` | |

BigQuery validates SQL when views, materialized views, routines and scheduled queries are created, so creation order matters. `depends_on` between these resources encodes it:

```
validation
   ├── connections ──────────────────────────────┐
   └── datasets ── tables ── materialized views ──┼── routines ── views ──┬── authorizations
                      │                            │                     └── transfers
                      └── access grants            └── (connection references)
```

- Tables, materialized views, routines and views are four resources, not one, because Terraform orders resources, not instances of one resource.
- Views come after routines because views often call UDFs. Table-valued functions that read views are the exception that is not supported in one configuration.
- Authorizations come after the objects they name, because BigQuery accepts only authorizations for existing views and routines.
- Resources inside one resource block are created in parallel. That is why views on views need separate module calls ([views.md](views.md#views-on-views)).

## Decisions

**Mappings, not lists.** Collections are keyed by name, which becomes the for_each key and the Terraform address. Reordering entries never changes addresses, and a duplicate key is impossible, or a YAML error at worst. Overriding the ID (`dataset_id`, ...) keeps the address stable while the BigQuery ID changes.

**Flat sections with a dataset reference.** Tables, views, materialized views and routines are top-level sections, and each entry names its dataset with `dataset: <key>`, as transfers name theirs with `destination_dataset_id`. Every section is at most two levels deep, no matter how many datasets there are, and a long file reads as one list per kind of resource. (v1 nested them inside their dataset; see [upgrading.md](upgrading.md).)

They are still addressed by `"<dataset key>.<key>"`, not by their key alone. That string reads like BigQuery's own `dataset.table`, it is what references to them look like, and it kept every v1 address unchanged, so upgrading needs no state moves. Because `.` separates the two parts, keys cannot contain one. `dataset` must name a key under `datasets` rather than any dataset ID, so a typo is caught at plan time instead of failing in BigQuery during apply. A dataset managed elsewhere is declared with `create: false`, which also supplies its project and location.

**Non-authoritative dataset access.** Grants and authorizations are separate `google_bigquery_dataset_access` resources, not `access` blocks on the dataset. The alternatives each have a problem:
- `access` blocks on the dataset are authoritative. They cannot include authorized views created in the same apply, because the dataset must exist before the views that authorize themselves on it.
- `google_bigquery_dataset_iam_*` rewrites the whole access list and drops authorized views.

`google_bigquery_dataset_access` serialises its updates per dataset (a provider mutex), so parallel grants are safe. Roles are normalised to the basic names BigQuery stores (`READER`, ...) so that the keys stay stable and plans stay clean.

**The JSON Schema is the source of truth for keys.** `validation.tf` reads the allowed keys of every object from the schema. Editor validation and module validation cannot drift. A test checks that every definition name used by `validation.tf` exists, and that the forbidden defaults refer to real keys.

**Validation gates everything.** The provider validates each planned instance before any precondition runs. Without gating, an invalid file would fail with provider messages about module internals. With `for_each = { ... if local.config_valid }`, nothing is planned and only the aggregated message is shown. The flag must never be unknown at plan time. For that reason no `contains()` or other function receives a possibly-null value, since a null makes the result unknown and would make `for_each` fail.

**Defaults are shallow, labels are deep.** A shallow merge is predictable: what you set on a resource is what you get. Labels and dataset access are the two collections that are naturally additive.

**Opinionated defaults only where safe.** Views default to `deletion_protection: false` because they hold no data. Tables and materialized views keep the provider default (`true`). The module never creates resources that are not in the file.

**Secrets through a variable.** YAML files end up in version control, and the `secrets` variable keeps credentials out of them. A variable marked sensitive also keeps the values out of plan output.

**`config_file` is always rendered.** Placeholders work without extra settings. The cost is escaping literal `${`, which is rare in YAML and SQL. Referenced files are rendered only with the `.tftpl` suffix, so JavaScript and plain SQL never need escaping.

## Not supported, on purpose

- **Instance-level ordering** (views on views, foreign keys between new tables). This would need a dependency graph inside one resource block, which Terraform does not offer. Emulating it with depth-numbered resources would move resources between addresses whenever a dependency changes, deleting and recreating tables.
- **Row access policies, data policies and policy-tag taxonomies.** These are separate resources with their own life cycle, better managed next to this module.
- **Reservations, capacity commitments and Analytics Hub.** These are platform-level resources with a different owner and cadence.
