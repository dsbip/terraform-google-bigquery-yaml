# Loading the configuration: files, inline YAML, templating, projects, paths.

mock_provider "google" {}

variables {
  project_id = "test-project"
}

run "config_file_is_rendered_with_template_vars" {
  command = plan

  variables {
    config_file = "tests/fixtures/templated.yaml"
    template_vars = {
      env      = "dev"
      location = "EU"
    }
  }

  assert {
    condition     = google_bigquery_dataset.this["events"].dataset_id == "events_dev"
    error_message = "template_vars were not substituted in the dataset ID."
  }
  assert {
    condition     = google_bigquery_dataset.this["events"].description == "Events for dev in test-project"
    error_message = "project_id should be available to the config template."
  }
  assert {
    condition     = google_bigquery_dataset.this["events"].location == "EU"
    error_message = "defaults.location was not applied from the rendered template."
  }
  assert {
    condition     = google_bigquery_dataset.this["events"].labels == tomap({ environment = "dev" })
    error_message = "defaults.labels were not applied."
  }
}

run "tftpl_files_are_rendered_and_others_are_not" {
  command = plan

  variables {
    config_file = "tests/fixtures/templated.yaml"
    template_vars = {
      env      = "prod"
      location = "US"
    }
  }

  # Relative paths resolve against the directory of config_file; *.tftpl files
  # get project_id, datasets.<key> (the real dataset ID) and template_vars.
  assert {
    condition     = trimspace(google_bigquery_table.view["events.latest"].view[0].query) == "SELECT * FROM `test-project.events_prod.raw` WHERE env = 'prod'"
    error_message = "The .tftpl query was not rendered: ${google_bigquery_table.view["events.latest"].view[0].query}"
  }
  assert {
    condition     = trimspace(google_bigquery_table.view["events.static"].view[0].query) == "SELECT '$${not_rendered}' AS literal"
    error_message = "A plain .sql file must be used verbatim."
  }
}

run "config_yaml_is_used_verbatim" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          description: "Uses $${literal} placeholders"
    EOT
  }

  assert {
    condition     = google_bigquery_dataset.this["sales"].description == "Uses $${literal} placeholders"
    error_message = "config_yaml must not be template-rendered."
  }
}

run "yamlencode_output_works_as_config_yaml" {
  command = plan

  variables {
    config_yaml = yamlencode({
      datasets = {
        generated = { description = "Built in HCL" }
      }
      tables = {
        events = { dataset = "generated" }
      }
    })
  }

  assert {
    condition = (
      google_bigquery_dataset.this["generated"].description == "Built in HCL" &&
      google_bigquery_table.table["generated.events"].dataset_id == "generated"
    )
    error_message = "yamlencode() output should be accepted."
  }
}

run "blank_and_comment_only_files_create_nothing" {
  command = plan

  variables {
    config_file = "tests/fixtures/blank.yaml"
  }

  assert {
    condition     = length(google_bigquery_dataset.this) == 0 && length(local.validation_errors) == 0
    error_message = "A comment-only file must be valid and empty."
  }
}

run "empty_sections_are_ignored" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
      datasets:
        sales:
      tables:
      views:
      materialized_views:
      routines:
      connections:
      transfers:
    EOT
  }

  assert {
    condition     = length(google_bigquery_dataset.this) == 1 && length(local.validation_errors) == 0
    error_message = "Keys without values must be treated as empty."
  }
}

run "yaml_project_id_takes_precedence_over_variable" {
  command = plan

  variables {
    config_yaml = <<-EOT
      project_id: yaml-project
      datasets:
        a: {}
        b:
          project_id: dataset-project
    EOT
  }

  assert {
    condition     = google_bigquery_dataset.this["a"].project == "yaml-project"
    error_message = "The YAML project_id should win over the project_id variable."
  }
  assert {
    condition     = google_bigquery_dataset.this["b"].project == "dataset-project"
    error_message = "A dataset-level project_id should win over the top-level one."
  }
  assert {
    condition     = output.project_id == "yaml-project"
    error_message = "output.project_id should report the resolved default project."
  }
}

run "variable_project_id_is_the_fallback" {
  command = plan

  variables {
    config_yaml = "datasets:\n  a: {}\n"
  }

  assert {
    condition     = google_bigquery_dataset.this["a"].project == "test-project"
    error_message = "The project_id variable should be used when the YAML has none."
  }
}

run "base_path_resolves_files_for_config_yaml" {
  command = plan

  variables {
    base_path   = "tests/fixtures"
    config_yaml = <<-EOT
      datasets:
        sales:

      tables:
        orders:
          dataset: sales
          schema_file: schemas/orders.json
    EOT
  }

  assert {
    condition     = jsondecode(google_bigquery_table.table["sales.orders"].schema)[0].name == "order_id"
    error_message = "schema_file should resolve against base_path."
  }
}

run "common_labels_variable_is_applied_everywhere" {
  command = plan

  variables {
    labels      = { owner = "platform", env = "test" }
    config_yaml = <<-EOT
      defaults:
        labels:
          env: from-defaults
      datasets:
        sales:
          labels:
            team: sales

      tables:
        t: { dataset: sales }

      views:
        v:
          dataset: sales
          query: SELECT 1
    EOT
  }

  assert {
    condition     = google_bigquery_dataset.this["sales"].labels == tomap({ owner = "platform", env = "from-defaults", team = "sales" })
    error_message = "Dataset labels should merge variable < defaults < dataset."
  }
  assert {
    condition     = google_bigquery_table.table["sales.t"].labels == tomap({ owner = "platform", env = "from-defaults" })
    error_message = "Tables should get the common and default labels, not the dataset's."
  }
  assert {
    condition     = google_bigquery_table.view["sales.v"].labels == tomap({ owner = "platform", env = "from-defaults" })
    error_message = "Views should get the common and default labels."
  }
}

# --- errors -------------------------------------------------------------------

run "missing_config_file_is_rejected" {
  command = plan

  variables {
    config_file = "tests/fixtures/does-not-exist.yaml"
  }

  expect_failures = [var.config_file]
}

run "no_configuration_is_rejected" {
  command = plan

  expect_failures = [terraform_data.validation]

  assert {
    condition     = contains(local.validation_errors, "Set the config_file or the config_yaml variable.")
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "both_configurations_are_rejected" {
  command = plan

  variables {
    config_file = "tests/fixtures/blank.yaml"
    config_yaml = "datasets: {}"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition     = contains(local.validation_errors, "Set only one of the config_file and config_yaml variables.")
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "missing_project_is_rejected" {
  command = plan

  variables {
    project_id  = null
    config_yaml = "datasets:\n  a: {}\nconnections:\n  c:\n    cloud_resource: {}\n"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition     = anytrue([for e in local.validation_errors : startswith(e, "No project ID for datasets.a, connections.c")])
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "non_mapping_root_is_rejected" {
  command = plan

  variables {
    config_yaml = "- datasets\n- tables\n"
  }

  expect_failures = [terraform_data.validation]

  assert {
    condition     = contains(local.validation_errors, "(root): must be a mapping (key: value pairs)")
    error_message = "Unexpected messages: ${jsonencode(local.validation_errors)}"
  }
}

run "template_vars_must_be_a_map" {
  command = plan

  variables {
    config_yaml   = "datasets: {}"
    template_vars = ["not", "a", "map"]
  }

  expect_failures = [var.template_vars]
}
