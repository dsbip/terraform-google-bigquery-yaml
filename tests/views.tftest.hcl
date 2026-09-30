# Logical and materialized views.

mock_provider "google" {}

variables {
  project_id = "test-project"
  base_path  = "tests/fixtures"
}

run "view_defaults" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        reporting:
          views:
            v:
              description: A view
              friendly_name: V
              query: SELECT 1 AS one
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.view["reporting.v"].view[0].query == "SELECT 1 AS one" &&
      google_bigquery_table.view["reporting.v"].view[0].use_legacy_sql == false &&
      google_bigquery_table.view["reporting.v"].deletion_protection == false &&
      google_bigquery_table.view["reporting.v"].description == "A view" &&
      google_bigquery_table.view["reporting.v"].friendly_name == "V"
    )
    error_message = "Views should default to GoogleSQL and no deletion protection."
  }
}

run "view_defaults_can_be_overridden" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        views:
          deletion_protection: true
      datasets:
        reporting:
          views:
            protected:
              query: SELECT 1
            legacy:
              query: SELECT 1
              use_legacy_sql: true
              deletion_protection: false
              deletion_policy: ABANDON
              expiration_time: 1893456000000
    EOT
  }

  assert {
    condition     = google_bigquery_table.view["reporting.protected"].deletion_protection == true
    error_message = "defaults.views.deletion_protection should override the module default."
  }
  assert {
    condition = (
      google_bigquery_table.view["reporting.legacy"].view[0].use_legacy_sql == true &&
      google_bigquery_table.view["reporting.legacy"].deletion_protection == false &&
      google_bigquery_table.view["reporting.legacy"].deletion_policy == "ABANDON" &&
      google_bigquery_table.view["reporting.legacy"].expiration_time == 1893456000000
    )
    error_message = "View-level settings should win."
  }
}

run "view_query_from_files" {
  command = plan

  variables {
    template_vars = { env = "qa" }
    config_yaml   = <<-EOT
      datasets:
        events:
          dataset_id: events_qa
          views:
            templated:
              query_file: sql/latest.sql.tftpl
            plain:
              query_file: sql/static.sql
    EOT
  }

  assert {
    condition     = trimspace(google_bigquery_table.view["events.templated"].view[0].query) == "SELECT * FROM `test-project.events_qa.raw` WHERE env = 'qa'"
    error_message = "The .tftpl view query was not rendered correctly."
  }
  assert {
    condition     = trimspace(google_bigquery_table.view["events.plain"].view[0].query) == "SELECT '$${not_rendered}' AS literal"
    error_message = "A .sql file must not be rendered."
  }
}

run "materialized_views" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        materialized_views:
          enable_refresh: true
          refresh_interval_ms: 1800000
      datasets:
        core:
          materialized_views:
            daily:
              description: Daily totals
              query: SELECT d, SUM(x) AS s FROM `p.core.t` GROUP BY d
              time_partitioning: { field: d }
              clustering: [d]
              max_staleness: "0-0 0 0:30:0"
              allow_non_incremental_definition: true
            by_range:
              query: SELECT id FROM `p.core.t`
              range_partitioning:
                field: id
                range: { start: 0, end: 10, interval: 1 }
              enable_refresh: false
              deletion_protection: false
    EOT
  }

  assert {
    condition = (
      google_bigquery_table.materialized_view["core.daily"].materialized_view[0].query == "SELECT d, SUM(x) AS s FROM `p.core.t` GROUP BY d" &&
      google_bigquery_table.materialized_view["core.daily"].materialized_view[0].enable_refresh == true &&
      google_bigquery_table.materialized_view["core.daily"].materialized_view[0].refresh_interval_ms == 1800000 &&
      google_bigquery_table.materialized_view["core.daily"].materialized_view[0].allow_non_incremental_definition == true
    )
    error_message = "Materialized view settings or defaults are wrong."
  }
  assert {
    condition = (
      google_bigquery_table.materialized_view["core.daily"].time_partitioning[0].field == "d" &&
      google_bigquery_table.materialized_view["core.daily"].clustering == tolist(["d"]) &&
      google_bigquery_table.materialized_view["core.daily"].max_staleness == "0-0 0 0:30:0"
    )
    error_message = "Materialized view partitioning/clustering is wrong."
  }
  assert {
    condition     = google_bigquery_table.materialized_view["core.daily"].deletion_protection == null
    error_message = "Materialized views should keep the provider deletion protection default."
  }
  assert {
    condition = (
      google_bigquery_table.materialized_view["core.by_range"].materialized_view[0].enable_refresh == false &&
      google_bigquery_table.materialized_view["core.by_range"].range_partitioning[0].range[0].end == 10 &&
      google_bigquery_table.materialized_view["core.by_range"].deletion_protection == false
    )
    error_message = "Materialized view overrides are wrong."
  }
}

run "view_and_materialized_view_iam" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        reporting:
          views:
            v:
              query: SELECT 1
              iam:
                - role: roles/bigquery.dataViewer
                  members: [group:bi@example.com]
          materialized_views:
            mv:
              query: SELECT 1
              iam:
                - role: roles/bigquery.dataViewer
                  members: [group:bi@example.com]
    EOT
  }

  assert {
    condition = toset(keys(google_bigquery_table_iam_member.this)) == toset([
      "reporting.v|roles/bigquery.dataViewer|group:bi@example.com",
      "reporting.mv|roles/bigquery.dataViewer|group:bi@example.com",
    ])
    error_message = "View and materialized view IAM members are wrong."
  }
}
