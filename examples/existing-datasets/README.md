# Existing datasets

Adding to datasets that this configuration does not own:

| Dataset | `create` | Managed here |
|---|---|---|
| `legacy_warehouse` (key `warehouse`) | `false` | A new table `campaign_spend`; read access for marketing; an authorization for every view in `marketing` |
| `reference_data` in another project (key `reference`) | `false` | An authorization for the `marketing.campaign_performance` view |
| `marketing` | `true` | The dataset, its access grant and the `campaign_performance` view |

Nothing about the existing datasets themselves changes: their settings, labels and other grants stay as they are. Grants and authorizations are separate resources that add entries to the datasets' access lists.

## Run

```bash
terraform init
terraform apply -var project_id=my-project \
  -var reference_project=shared-reference-data \
  -var marketing_group=marketing@your-domain.com
```

Prerequisites:

- `legacy_warehouse` exists in `my-project`.
- `reference_data.countries` exists in `reference_project`, and you may update that dataset's access list (`bigquery.datasets.update`).

`terraform destroy` removes the view, the new table, the grants and the authorizations. The existing datasets remain.
