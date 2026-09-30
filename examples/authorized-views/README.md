# Authorized views

Sharing sensitive HR data without giving anyone access to it:

| Dataset | Holds | Who can read it |
|---|---|---|
| `hr_private` | `employees`, with salaries and national IDs | the HR team (`WRITER`) |
| `hr_shared` | `employee_directory` and `headcount_by_department` views, and the `employees_in_department(dept)` table function | all employees |
| `hr_analytics` | `tenure_distribution` view | the people analytics team |

`hr_private` authorizes:

- the two views in `hr_shared` (`authorized_views`),
- every view in `hr_analytics` (`authorized_datasets`),
- the table function (`authorized_routines`).

Readers of `hr_shared` can see names and departments but never salaries, even though the views read `hr_private`.

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var hr_team_group=hr@your-domain.com \
  -var all_employees_group=everyone@your-domain.com \
  -var people_analytics_group=people-analytics@your-domain.com
```

The groups must exist; BigQuery rejects grants to unknown groups.

## Try it

Query `hr_shared.employee_directory` or `SELECT * FROM hr_shared.employees_in_department('Sales')` as a member of the all-employees group. The same user gets `Access Denied` on `hr_private.employees`.

See [docs/authorized-views.md](../../docs/authorized-views.md) for how references resolve.
