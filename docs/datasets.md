# Datasets

```yaml
datasets:
  sales:
    description: Orders and customers.
    location: EU
    labels: { domain: sales }
    default_table_expiration_ms: 7776000000
    access:
      - role: READER
        members: [group:analysts@example.com]

tables:
  orders:
    dataset: sales     # tables, views and routines name their dataset by key
```

A bare key creates a dataset with defaults only: `sales: {}` or just `sales:`.

Tables, views, materialized views and routines are defined in their own top-level sections ([tables](tables.md), [views](views.md), [routines](routines.md)), not inside the dataset. Each one names its dataset with `dataset: <key>` and takes the dataset's project, ID and location ([configuration.md](configuration.md#the-dataset-of-a-table-view-or-routine)).

## Keys

| Key | Type | Default | Description |
|---|---|---|---|
| `dataset_id` | string | map key | Dataset ID. |
| `project_id` | string | [resolved](configuration.md#projects) | Project of the dataset, and of the tables, views and routines that reference it. |
| `create` | bool | `true` | `false` for a dataset that exists already; see [Existing datasets](#existing-datasets). |
| `location` | string | [resolved](configuration.md#locations) | `US`, `EU` or a region. Changing it replaces the dataset. |
| `friendly_name` | string | | Display name. |
| `description` | string | | |
| `labels` | map | | Merged with default labels ([labels](configuration.md#labels)). |
| `default_table_expiration_ms` | number | | Lifetime of new tables (minimum 3600000). |
| `default_partition_expiration_ms` | number | | Lifetime of partitions in new partitioned tables. |
| `delete_contents_on_destroy` | bool | `false` | Allow `terraform destroy` to delete a dataset that still contains tables. |
| `deletion_policy` | `DELETE`, `PREVENT`, `ABANDON` | `DELETE` | `PREVENT` makes destroy fail; `ABANDON` removes the dataset from state only. |
| `is_case_insensitive` | bool | | Case-insensitive dataset and table names. |
| `default_collation` | string | | `und:ci` for case-insensitive collation; `""` clears it. |
| `max_time_travel_hours` | number | 168 | Time travel window, 48 to 168 hours. |
| `storage_billing_model` | `LOGICAL`, `PHYSICAL` | | Storage billing model. |
| `resource_tags` | map | | Resource Manager tags: `{"123456789012/environment": "production"}`. |
| `default_encryption_configuration` | `{kms_key_name}` | | Default Cloud KMS key for new tables. |
| `external_dataset_reference` | `{external_source, connection}` | | Federated dataset, e.g. over an AWS Glue database. `connection` may be a [connection key](configuration.md#references). |
| `external_catalog_dataset_options` | `{default_storage_location_uri, parameters}` | | Open-source catalog (Hive/Iceberg) options. |
| `access` | list | | [Access grants](#access-grants). |
| `authorized_views`, `authorized_datasets`, `authorized_routines` | list | | See [authorized-views.md](authorized-views.md). |

Keys cannot contain `.`. A v1 configuration with `tables`, `views`, `materialized_views` or `routines` inside a dataset fails validation with a pointer to [upgrading.md](upgrading.md).

## Access grants

`access` grants dataset-level roles:

```yaml
access:
  - role: READER                          # or roles/bigquery.dataViewer
    members:
      - group:analysts@example.com
      - user:jane@example.com
      - serviceAccount:etl@my-project.iam.gserviceaccount.com
      - domain:example.com
      - specialGroup:projectReaders
  - role: roles/bigquery.metadataViewer   # any predefined or custom role
    members: [group:catalog@example.com]
    condition:                            # optional IAM condition
      title: until-2027
      expression: request.time < timestamp("2027-01-01T00:00:00Z")
```

| Key | Required | Description |
|---|---|---|
| `role` | yes | `OWNER`, `WRITER`, `READER`, or any predefined or custom role. |
| `members` | yes | See the table below. |
| `condition` | no | `expression` is required; `title`, `description` and `location` are optional. |

| Member | Becomes |
|---|---|
| `user:EMAIL`, `serviceAccount:EMAIL` | `user_by_email` |
| `group:EMAIL` | `group_by_email` |
| `domain:DOMAIN` | `domain` |
| `specialGroup:NAME`, or bare `projectOwners`, `projectWriters`, `projectReaders`, `allAuthenticatedUsers` | `special_group` |
| `allUsers`, `principal://...`, `principalSet://...` | `iam_member` |
| `iamMember:MEMBER` | `iam_member` with the given value |

### How grants are managed

Each role and member pair is one `google_bigquery_dataset_access` resource, keyed `"<dataset key>|<role>|<member>"`:

- **Non-authoritative.** Only the grants in the file are managed. BigQuery's default entries (project owners, writers and readers, and the creator) and grants added by others are left alone. Removing a grant from the file deletes that grant only.
- **Compatible with authorized views.** Authorizations use the same resource type, so grants and authorizations on one dataset never overwrite each other.
- **Role normalisation.** `roles/bigquery.dataOwner`, `dataEditor` and `dataViewer` are stored by BigQuery as `OWNER`, `WRITER` and `READER`. The module converts them the same way, so the plan stays clean and both spellings refer to the same grant.
- **Duplicates collapse.** The same grant listed twice (for example in `defaults.datasets.access` and on the dataset) is created once.

Do not manage the same dataset with `google_bigquery_dataset_iam_policy`, `_iam_binding` or `_iam_member`, or with `access` blocks on another `google_bigquery_dataset` resource. Those manage the dataset's access list as a whole and would remove grants and authorizations made by this module. Grant through this module, or through `google_bigquery_dataset_access` elsewhere.

## Existing datasets

`create: false` declares a dataset that exists already, for example one created by another team or an older setup. The module does not create or change the dataset, but manages its grants and authorizations, and tables, views and routines can reference it with `dataset:`:

```yaml
datasets:
  warehouse:
    create: false
    project_id: legacy-project     # if different from the default
    dataset_id: legacy_warehouse
    location: US                   # optional; used as the location of transfers writing here
    access:
      - role: READER
        members: [group:marketing@example.com]
    authorized_views: [marketing.campaign_performance]

tables:
  campaign_spend:
    dataset: warehouse             # created in legacy-project.legacy_warehouse
    schema_file: schemas/campaign_spend.json
```

Only `dataset_id`, `project_id`, `create`, `location`, `access` and `authorized_*` are allowed on such a dataset; other settings would have no effect, and validation rejects them. `defaults.datasets.access` applies to existing datasets too.

The [existing-datasets example](../examples/existing-datasets) shows this, including an authorization on a dataset in another project.

## Deletion

A dataset can only be deleted when it is empty, unless `delete_contents_on_destroy: true`. The tables it contains have their own `deletion_protection`, which defaults to `true` ([tables.md](tables.md#deletion-protection)). For production datasets, `deletion_policy: PREVENT` makes any plan that would delete the dataset fail.
