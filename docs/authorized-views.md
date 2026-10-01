# Authorized views, datasets and routines

An **authorized view** can read a dataset that the people querying the view cannot read. You share curated or aggregated data by giving readers access to the view's dataset only. The same mechanism exists for whole datasets (every view in the dataset is authorized) and for routines (such as table-valued functions).

Authorization is a property of the **source** dataset, the one holding the private data, so it is configured there:

```yaml
datasets:
  hr_private:                        # the sensitive data
    access:
      - role: WRITER
        members: [group:hr-team@example.com]
    authorized_views:
      - employee_directory                 # a view key from this file
      - hr_shared.headcount_by_department  # or "<dataset key>.<view key>"
    authorized_datasets:
      - hr_analytics                       # every view in hr_analytics
    authorized_routines:
      - employees_in_department            # a table-valued function

  hr_shared:                         # what employees may read
    access:
      - role: READER
        members: [group:all-employees@example.com]

  hr_analytics: {}                   # its views are in the views section

tables:
  employees: { dataset: hr_private, ... }

views:
  employee_directory:
    dataset: hr_shared
    query: SELECT employee_id, full_name, email FROM `${project_id}.hr_private.employees`
  headcount_by_department:
    dataset: hr_shared
    query: SELECT department, COUNT(*) AS headcount FROM `${project_id}.hr_private.employees` GROUP BY department

routines:
  employees_in_department: { dataset: hr_shared, ... }
```

People in `all-employees` can query the views in `hr_shared` but not `hr_private.employees`. The [authorized-views example](../examples/authorized-views) is a complete version.

## References

| List | Entry forms |
|---|---|
| `authorized_views` | `"view key"`, `"dataset.view"`, `"project.dataset.view"`, `{project_id, dataset_id, table_id}` |
| `authorized_datasets` | `"dataset"`, `"project.dataset"`, `{project_id, dataset_id, target_types}` |
| `authorized_routines` | `"routine key"`, `"dataset.routine"`, `"project.dataset.routine"`, `{project_id, dataset_id, routine_id}` |

String references resolve in this order:

1. A view, materialized view or routine **declared in this file**, written as `"<dataset key>.<key>"` (`hr_shared.employee_directory`) or as its key alone (`employee_directory`) → its real project, dataset ID and ID, including any `dataset_id` / `table_id` / `routine_id` overrides. If a view and a materialized view share a key, use the `"<dataset key>.<key>"` form.
2. A dataset key from this file followed by a name (`hr_shared.some_view`) → that dataset's real IDs.
3. Otherwise the reference is used as written; without a project, the source dataset's project is used.

Materialized views can be authorized the same way as views. `target_types` for authorized datasets defaults to `[VIEWS]`, the only type BigQuery supports today.

## How it is applied

Each entry becomes a `google_bigquery_dataset_access` resource on the source dataset, created **after** the views and routines it refers to. BigQuery only accepts authorizations for objects that exist. Entries are keyed `"<source dataset key>|<project>.<dataset>.<name>"`.

Because these entries are separate resources:

- they coexist with the dataset's [access grants](datasets.md#access-grants) and with entries added outside Terraform;
- the source dataset can be one that this configuration does not create (`create: false`), even in another project, as long as you are allowed to update its access list ([existing-datasets example](../examples/existing-datasets));
- views authorized from another configuration only need a `create: false` entry for the source dataset in that configuration ([layered-views example](../examples/layered-views)).

## Things to know

- An authorized view reads the source dataset with the view's own authorization, so a query through it **bypasses the source dataset's access list**. Review view SQL like any other access grant.
- Authorization entries removed outside Terraform (by hand, or by BigQuery when a view is dropped and recreated) show up in the next plan and are restored by apply.
- If a view reads several private datasets, authorize it on each of them.
- Do not use `google_bigquery_dataset_iam_*` resources on the source dataset; they replace the whole access list and drop authorizations ([datasets.md](datasets.md#how-grants-are-managed)).
