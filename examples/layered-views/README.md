# Layered views

Views that select from other views need those views to exist first. Inside one configuration, views are created in parallel, so layers go into separate files and module calls:

| File | Module call | Contents |
|---|---|---|
| `base.yaml` | `module.base` | Dataset `staging` with table `orders_raw` and the deduplicating view `orders` |
| `marts.yaml` | `module.marts` (`depends_on = [module.base]`) | Dataset `marts` with `customer_revenue` and `daily_revenue`, both reading `staging.orders` |

`marts.yaml` also declares `staging` with `create: false` and authorizes the `marts` dataset on it. Readers of `marts` get results without having access to `staging`. The authorization is created by the second module call, on a dataset owned by the first.

## Run

```bash
terraform init
terraform apply -var project_id=my-project
```

`depends_on` also orders destruction: `terraform destroy` removes the marts layer before the base layer.

The same pattern splits large estates by domain or team: one YAML file per domain, with `depends_on` only where one domain reads another.
