# Contributing

Issues and pull requests are welcome.

## Before you start

- Read [docs/design.md](docs/design.md): it explains how configuration flows through the module and why it is built the way it is.
- For a larger change, open an issue first to agree on the YAML shape; the configuration format is the module's public interface.

## Making a change

1. Add or change the key in `schemas/bigquery-config.schema.json`, with a description. The module reads its allowed keys from this file. If the `.tf` code starts to depend on something new in the schema (a new definition, a new top-level section), bump `"x-schema-revision"` in the schema and `schema_revision` in `main.tf` together, so that a copy of the module with an older schema file is reported clearly.
2. Normalise the value in the resource's `.tf` file. Keep the pattern of the surrounding code:
   - wrap lookups in `try()` so bad input reaches validation instead of failing the plan;
   - represent nested blocks as 0/1-element lists;
   - never pass a value that may be null to `contains()` or `lookup()`.
3. Add validation to `validation.tf` for invalid combinations, with a message that starts with the YAML path.
4. Add tests in `tests/`: a unit test that asserts the planned attribute, and a validation test that compares the full set of messages if you added a check.
5. Update the relevant page in `docs/`, and an example if the feature is commonly used.
6. Add an entry under "Unreleased" in [CHANGELOG.md](CHANGELOG.md).

## Checks

```bash
scripts/test.sh
```

This runs `terraform fmt -check`, `terraform validate`, `terraform test` and the Python tests (schema checks and real-provider plans of every example). CI runs the same checks across the supported Terraform and provider versions. See [docs/testing.md](docs/testing.md).

## Compatibility

- Keep Terraform 1.5 working in the module code: logical operators do not short-circuit before Terraform 1.12, and functions newer than 1.5 are unavailable. CI plans every example with Terraform 1.5.7.
- Keep google provider 7.42 working, or raise the minimum in `versions.tf` and the CI matrix together, and note it in the changelog.
- Changing a resource's `for_each` key or address is a breaking change: users' resources would be destroyed and recreated. Avoid it, or ship `moved` blocks.

## Releases

Versions follow semantic versioning. A release is a `vX.Y.Z` tag on `main` with the changelog section as release notes.
