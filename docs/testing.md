# Testing

The module is tested in four layers. The first three need no Google Cloud access and run in CI on every push; the live test runs on demand.

| Layer | Tool | What it proves | Where |
|---|---|---|---|
| Static | `terraform fmt`, `terraform validate` | Formatting; valid HCL against the provider schema | module root |
| Unit | `terraform test` with a mocked provider | Every feature, default, precedence rule, reference resolution and validation message | `tests/*.tftest.hcl` (81 tests) |
| Plan | pytest + real provider, dummy credentials | Every example and the live fixture pass the real provider's validation and plan logic; examples match the JSON Schema; schema and module agree | `tests/python/test_example_plans.py`, `test_schema.py` |
| Live | pytest + real provider, real project | Resources deploy, a second plan is empty (no drift), in-place updates work, destroy is clean | `tests/python/test_live.py`, `tests/integration/` |

## Requirements

- Terraform >= 1.7 for the unit tests (mock providers); the module itself supports >= 1.5
- Python >= 3.9 with `pip install -r tests/python/requirements.txt` (pytest, PyYAML, jsonschema)
- Network access to download providers

## Running the tests

Everything offline, in one command (Linux, macOS, or Git Bash on Windows):

```bash
scripts/test.sh
```

Or step by step from the repository root:

```bash
terraform fmt -check -recursive
terraform init -backend=false && terraform validate
terraform test                                    # unit tests
python -m pytest tests/python -v                  # schema and real-provider plans
```

A single unit test file: `terraform test -filter=tests/tables.tftest.hcl` (on Windows: `-filter=tests\tables.tftest.hcl`).

To check the minimum versions, run the plan tests with Terraform 1.5.7 and pin the provider:

```bash
TERRAFORM_BIN=/path/to/terraform-1.5.7 GOOGLE_PROVIDER_VERSION=7.42.0 python -m pytest tests/python -v
```

## Unit tests

Each file in `tests/` covers one area: `config`, `datasets`, `tables`, `views`, `authorized`, `routines`, `connections`, `transfers`, `validation`, `examples`. Runs use inline YAML (`config_yaml`) or fixtures from `tests/fixtures/`, and assert on planned attributes. Most runs are `command = plan`; a few use `command = apply`, where the mocked provider fills in computed attributes such as a connection's name.

Validation tests plant several mistakes and compare the complete set of messages:

```hcl
run "table_rules" {
  command = plan
  variables { config_yaml = <<-EOT ... EOT }
  expect_failures = [terraform_data.validation]
  assert {
    condition = toset(local.validation_errors) == toset([
      "datasets.sales.tables.both_schemas: set schema or schema_file, not both",
      ...
    ])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}
```

A missing message or a spurious extra one both fail the test.

## Plan tests

`test_example_plans.py` copies the repository to a temporary directory and runs `terraform init` and `terraform plan -refresh=false` in every example with a dummy `GOOGLE_OAUTH_ACCESS_TOKEN`. The provider needs no API calls to plan new resources, so the plans exercise its full validation and diff logic offline. Each test checks the exact number of planned resources. The live-test fixture is planned the same way, with all optional parts enabled, so it stays deployable.

`test_schema.py` validates the JSON Schema itself, checks that every example conforms to it and that invalid samples are rejected, and checks that the schema and `validation.tf` agree.

## Live test

The live test deploys `tests/integration/` into a real project. That fixture covers:
- three datasets, with access grants given in both role spellings,
- tables with partitioning, clustering, keys and a same-apply foreign key,
- a view, a materialized view and four kinds of routine,
- all three kinds of authorization,
- optionally IAM, a connection and a disabled scheduled query.

The test then runs:

1. `apply`
2. `plan -detailed-exitcode` must report no changes (catches permanent diffs)
3. `apply` with changed descriptions (in-place updates)
4. another empty plan
5. `destroy` (always, also after a failure)

All names start with `bqyaml_<random>`, and scheduled queries are created disabled, so a run costs next to nothing.

```bash
gcloud auth application-default login
export BQ_YAML_TEST_PROJECT=my-sandbox-project
export BQ_YAML_TEST_LOCATION=US                                   # optional
export BQ_YAML_TEST_MEMBER=user:me@example.com                    # optional: IAM grants
export BQ_YAML_TEST_CONNECTIONS=true                              # optional: needs the Connection API
export BQ_YAML_TEST_TRANSFERS=true                                # optional: needs the Data Transfer API
python -m pytest tests/python/test_live.py -v
```

The identity needs `roles/bigquery.admin` in the project, plus `roles/bigquery.connectionAdmin` for connections. If a run is interrupted before its destroy step, delete the leftover `bqyaml_*` datasets, connections and transfers by hand.

The **Live test** workflow runs the same test from GitHub Actions. To enable it:
1. Create a Workload Identity Federation provider for the repository.
2. Set the repository variables `BQ_YAML_TEST_PROJECT`, `GCP_WORKLOAD_IDENTITY_PROVIDER` and `GCP_SERVICE_ACCOUNT`.
3. Start the workflow from the Actions tab.

## Continuous integration

`.github/workflows/ci.yml` runs on pushes to `main` and on pull requests:

| Job | Terraform | Provider |
|---|---|---|
| fmt and validate | latest | latest |
| terraform test | 1.7.5, latest | 7.42.0, latest (4 combinations) |
| example plans and schema tests | 1.5.7 with 7.42.0 (the minimums), latest with latest | |

## Adding a feature

1. Add the key to the schema definition in `schemas/bigquery-config.schema.json` (with a description).
2. Normalise it in the resource's `.tf` file and pass it to the resource.
3. Add validation for invalid combinations, with a YAML-path message.
4. Add a unit test for the planned attribute, and a validation test if you added a check.
5. Use it in an example if it is a common case, and update the resource's page in `docs/`.
