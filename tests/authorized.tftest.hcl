# Authorized views, materialized views, datasets and routines.

mock_provider "google" {}

variables {
  project_id = "test-project"
}

run "authorized_view_references_resolve" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        private:
          authorized_views:
            - shared.v_managed          # view in this file (with overridden IDs)
            - shared.mv_managed         # materialized view in this file
            - shared.v_not_in_file      # dataset key in this file, view elsewhere
            - elsewhere.v               # dataset not in this file
            - other-project.ds.v        # fully qualified
            - example.com:scoped.ds.v   # domain-scoped project
            - { dataset_id: obj_ds, table_id: obj_v }
            - { project_id: obj-project, dataset_id: obj_ds, table_id: obj_v }
        shared:
          dataset_id: shared_prod
          project_id: shared-project
          views:
            v_managed:
              table_id: v_managed_v2
              query: SELECT 1
          materialized_views:
            mv_managed:
              query: SELECT 1
    EOT
  }

  assert {
    condition = toset(keys(google_bigquery_dataset_access.authorized_view)) == toset([
      "private|shared-project.shared_prod.v_managed_v2",
      "private|shared-project.shared_prod.mv_managed",
      "private|shared-project.shared_prod.v_not_in_file",
      "private|test-project.elsewhere.v",
      "private|other-project.ds.v",
      "private|example.com:scoped.ds.v",
      "private|test-project.obj_ds.obj_v",
      "private|obj-project.obj_ds.obj_v",
    ])
    error_message = "Unexpected authorized views: ${jsonencode(keys(google_bigquery_dataset_access.authorized_view))}"
  }
  assert {
    condition = (
      google_bigquery_dataset_access.authorized_view["private|shared-project.shared_prod.v_managed_v2"].dataset_id == "private" &&
      google_bigquery_dataset_access.authorized_view["private|shared-project.shared_prod.v_managed_v2"].view[0].project_id == "shared-project" &&
      google_bigquery_dataset_access.authorized_view["private|shared-project.shared_prod.v_managed_v2"].view[0].dataset_id == "shared_prod" &&
      google_bigquery_dataset_access.authorized_view["private|shared-project.shared_prod.v_managed_v2"].view[0].table_id == "v_managed_v2" &&
      google_bigquery_dataset_access.authorized_view["private|shared-project.shared_prod.v_managed_v2"].role == null
    )
    error_message = "The authorized view entry is wrong."
  }
}

run "authorized_datasets_and_routines" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        private:
          dataset_id: private_prod
          authorized_datasets:
            - shared                       # dataset key in this file
            - not_managed                  # dataset in the same project
            - other-project.analytics      # fully qualified
            - { project_id: p3, dataset_id: d3, target_types: [VIEWS] }
          authorized_routines:
            - shared.tvf                   # routine in this file
            - udfs.not_managed             # dataset elsewhere
            - other-project.udfs.fn
        shared:
          dataset_id: shared_prod
          routines:
            tvf:
              routine_id: tvf_v2
              routine_type: TABLE_VALUED_FUNCTION
              definition_body: SELECT 1 AS x
    EOT
  }

  assert {
    condition = toset(keys(google_bigquery_dataset_access.authorized_dataset)) == toset([
      "private|test-project.shared_prod",
      "private|test-project.not_managed",
      "private|other-project.analytics",
      "private|p3.d3",
    ])
    error_message = "Unexpected authorized datasets: ${jsonencode(keys(google_bigquery_dataset_access.authorized_dataset))}"
  }
  assert {
    condition = (
      google_bigquery_dataset_access.authorized_dataset["private|test-project.shared_prod"].dataset_id == "private_prod" &&
      google_bigquery_dataset_access.authorized_dataset["private|test-project.shared_prod"].dataset[0].target_types == tolist(["VIEWS"]) &&
      google_bigquery_dataset_access.authorized_dataset["private|test-project.shared_prod"].dataset[0].dataset[0].dataset_id == "shared_prod"
    )
    error_message = "The authorized dataset entry is wrong."
  }
  assert {
    condition = toset(keys(google_bigquery_dataset_access.authorized_routine)) == toset([
      "private|test-project.shared_prod.tvf_v2",
      "private|test-project.udfs.not_managed",
      "private|other-project.udfs.fn",
    ])
    error_message = "Unexpected authorized routines: ${jsonencode(keys(google_bigquery_dataset_access.authorized_routine))}"
  }
  assert {
    condition     = google_bigquery_dataset_access.authorized_routine["private|test-project.shared_prod.tvf_v2"].routine[0].routine_id == "tvf_v2"
    error_message = "The authorized routine entry is wrong."
  }
}

run "authorizations_on_existing_dataset_and_duplicates" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        legacy:
          create: false
          project_id: legacy-project
          dataset_id: warehouse
          authorized_views:
            - reporting.v
            - reporting.v          # listed twice
            -                      # empty item, ignored
        reporting:
          views:
            v:
              query: SELECT 1
    EOT
  }

  assert {
    condition = (
      length(google_bigquery_dataset_access.authorized_view) == 1 &&
      google_bigquery_dataset_access.authorized_view["legacy|test-project.reporting.v"].project == "legacy-project" &&
      google_bigquery_dataset_access.authorized_view["legacy|test-project.reporting.v"].dataset_id == "warehouse"
    )
    error_message = "Duplicates should collapse and apply to the existing dataset."
  }
}
