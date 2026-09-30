# Datasets and dataset access grants.

mock_provider "google" {}

variables {
  project_id = "test-project"
}

run "dataset_attributes_are_passed_through" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          friendly_name: Sales
          description: Sales data
          location: europe-west2
          default_table_expiration_ms: 7200000
          default_partition_expiration_ms: 86400000
          delete_contents_on_destroy: true
          deletion_policy: PREVENT
          is_case_insensitive: true
          default_collation: "und:ci"
          max_time_travel_hours: 96
          storage_billing_model: PHYSICAL
          resource_tags:
            "123456789012/environment": production
          default_encryption_configuration:
            kms_key_name: projects/p/locations/europe-west2/keyRings/r/cryptoKeys/k
          external_catalog_dataset_options:
            default_storage_location_uri: gs://bucket/warehouse
            parameters:
              owner: data-platform
    EOT
  }

  assert {
    condition = (
      google_bigquery_dataset.this["sales"].dataset_id == "sales" &&
      google_bigquery_dataset.this["sales"].project == "test-project" &&
      google_bigquery_dataset.this["sales"].friendly_name == "Sales" &&
      google_bigquery_dataset.this["sales"].description == "Sales data" &&
      google_bigquery_dataset.this["sales"].location == "europe-west2"
    )
    error_message = "Basic dataset attributes are wrong."
  }
  assert {
    condition = (
      google_bigquery_dataset.this["sales"].default_table_expiration_ms == 7200000 &&
      google_bigquery_dataset.this["sales"].default_partition_expiration_ms == 86400000 &&
      google_bigquery_dataset.this["sales"].delete_contents_on_destroy == true &&
      google_bigquery_dataset.this["sales"].deletion_policy == "PREVENT" &&
      google_bigquery_dataset.this["sales"].is_case_insensitive == true &&
      google_bigquery_dataset.this["sales"].default_collation == "und:ci"
    )
    error_message = "Dataset settings are wrong."
  }
  assert {
    condition     = google_bigquery_dataset.this["sales"].max_time_travel_hours == "96"
    error_message = "max_time_travel_hours should be converted to a string."
  }
  assert {
    condition     = google_bigquery_dataset.this["sales"].storage_billing_model == "PHYSICAL"
    error_message = "storage_billing_model is wrong."
  }
  assert {
    condition     = google_bigquery_dataset.this["sales"].resource_tags["123456789012/environment"] == "production"
    error_message = "resource_tags are wrong."
  }
  assert {
    condition     = google_bigquery_dataset.this["sales"].default_encryption_configuration[0].kms_key_name == "projects/p/locations/europe-west2/keyRings/r/cryptoKeys/k"
    error_message = "default_encryption_configuration is wrong."
  }
  assert {
    condition = (
      google_bigquery_dataset.this["sales"].external_catalog_dataset_options[0].default_storage_location_uri == "gs://bucket/warehouse" &&
      google_bigquery_dataset.this["sales"].external_catalog_dataset_options[0].parameters["owner"] == "data-platform"
    )
    error_message = "external_catalog_dataset_options are wrong."
  }
}

run "dataset_id_and_location_precedence" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        location: US
        datasets:
          location: EU
      datasets:
        plain: {}
        renamed:
          dataset_id: sales_v2
        pinned:
          location: asia-northeast1
    EOT
  }

  assert {
    condition     = google_bigquery_dataset.this["plain"].dataset_id == "plain"
    error_message = "dataset_id should default to the map key."
  }
  assert {
    condition     = google_bigquery_dataset.this["renamed"].dataset_id == "sales_v2"
    error_message = "dataset_id should override the map key."
  }
  assert {
    condition     = google_bigquery_dataset.this["plain"].location == "EU"
    error_message = "defaults.datasets.location should win over defaults.location."
  }
  assert {
    condition     = google_bigquery_dataset.this["pinned"].location == "asia-northeast1"
    error_message = "A dataset's own location should win over the defaults."
  }
}

run "defaults_location_applies_without_type_defaults" {
  command = plan

  variables {
    config_yaml = "defaults:\n  location: EU\ndatasets:\n  a: {}\n"
  }

  assert {
    condition     = google_bigquery_dataset.this["a"].location == "EU"
    error_message = "defaults.location should apply to datasets."
  }
}

run "null_values_do_not_override_defaults" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        datasets:
          description: From defaults
      datasets:
        a:
          description:
    EOT
  }

  assert {
    condition     = google_bigquery_dataset.this["a"].description == "From defaults"
    error_message = "An empty value must fall back to the default."
  }
}

run "existing_datasets_are_not_created" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        legacy:
          create: false
          dataset_id: legacy_dw
          project_id: other-project
          access:
            - role: READER
              members: [group:readers@example.com]
          tables:
            new_table: {}
    EOT
  }

  assert {
    condition     = length(google_bigquery_dataset.this) == 0
    error_message = "A create: false dataset must not be created."
  }
  assert {
    condition = (
      google_bigquery_table.table["legacy.new_table"].dataset_id == "legacy_dw" &&
      google_bigquery_table.table["legacy.new_table"].project == "other-project"
    )
    error_message = "Tables in an existing dataset should use its real IDs."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["legacy|READER|group:readers@example.com"].dataset_id == "legacy_dw"
    error_message = "Access grants should apply to existing datasets."
  }
}

run "access_members_map_to_the_right_fields" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          access:
            - role: roles/bigquery.dataViewer
              members:
                - user:jane@example.com
                - serviceAccount:etl@test-project.iam.gserviceaccount.com
                - group:analysts@example.com
                - domain:example.com
                - specialGroup:projectReaders
                - allAuthenticatedUsers
                - allUsers
                - iamMember:principal://goog/subject/jane
                - principalSet://iam.googleapis.com/locations/global/workforcePools/pool/group/admins
            - role: roles/bigquery.dataEditor
              members: [projectWriters]
            - role: roles/bigquery.dataOwner
              members: [group:owners@example.com]
            - role: roles/bigquery.metadataViewer
              members: [group:catalog@example.com]
    EOT
  }

  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|user:jane@example.com"].user_by_email == "jane@example.com"
    error_message = "user: should map to user_by_email."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|serviceAccount:etl@test-project.iam.gserviceaccount.com"].user_by_email == "etl@test-project.iam.gserviceaccount.com"
    error_message = "serviceAccount: should map to user_by_email."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|group:analysts@example.com"].group_by_email == "analysts@example.com"
    error_message = "group: should map to group_by_email."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|domain:example.com"].domain == "example.com"
    error_message = "domain: should map to domain."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|specialGroup:projectReaders"].special_group == "projectReaders"
    error_message = "specialGroup: should map to special_group."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|allAuthenticatedUsers"].special_group == "allAuthenticatedUsers"
    error_message = "allAuthenticatedUsers should map to special_group."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|allUsers"].iam_member == "allUsers"
    error_message = "allUsers should map to iam_member."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|iamMember:principal://goog/subject/jane"].iam_member == "principal://goog/subject/jane"
    error_message = "iamMember: should map to iam_member without the prefix."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|READER|principalSet://iam.googleapis.com/locations/global/workforcePools/pool/group/admins"].iam_member == "principalSet://iam.googleapis.com/locations/global/workforcePools/pool/group/admins"
    error_message = "principalSet:// identifiers should map to iam_member as written."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|WRITER|projectWriters"].special_group == "projectWriters"
    error_message = "Bare project special groups should map to special_group."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|OWNER|group:owners@example.com"].role == "OWNER"
    error_message = "roles/bigquery.dataOwner should be normalised to OWNER."
  }
  assert {
    condition     = google_bigquery_dataset_access.access["sales|roles/bigquery.metadataViewer|group:catalog@example.com"].role == "roles/bigquery.metadataViewer"
    error_message = "Other roles should be passed through unchanged."
  }
  assert {
    condition     = length(google_bigquery_dataset_access.access) == 12
    error_message = "Expected one access resource per role and member."
  }
  assert {
    condition = alltrue([
      for a in google_bigquery_dataset_access.access : length(compact([a.user_by_email, a.group_by_email, a.domain, a.special_group, a.iam_member])) == 1
    ])
    error_message = "Every access resource must set exactly one member field."
  }
}

run "default_access_is_prepended_and_deduplicated" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        datasets:
          access:
            - role: READER
              members: [group:platform@example.com]
      datasets:
        a: {}
        b:
          access:
            # The same grant as the default, spelled differently.
            - role: roles/bigquery.dataViewer
              members: [group:platform@example.com]
            - role: WRITER
              members: [user:bob@example.com]
    EOT
  }

  assert {
    condition = toset(keys(google_bigquery_dataset_access.access)) == toset([
      "a|READER|group:platform@example.com",
      "b|READER|group:platform@example.com",
      "b|WRITER|user:bob@example.com",
    ])
    error_message = "Unexpected access grants: ${jsonencode(keys(google_bigquery_dataset_access.access))}"
  }
}

run "access_condition_is_passed_through" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        sales:
          access:
            - role: READER
              members: [group:contractors@example.com]
              condition:
                title: Until end of contract
                expression: request.time < timestamp("2027-01-01T00:00:00Z")
                description: Temporary access
    EOT
  }

  assert {
    condition = (
      google_bigquery_dataset_access.access["sales|READER|group:contractors@example.com"].condition[0].title == "Until end of contract" &&
      google_bigquery_dataset_access.access["sales|READER|group:contractors@example.com"].condition[0].expression == "request.time < timestamp(\"2027-01-01T00:00:00Z\")"
    )
    error_message = "The access condition was not passed through."
  }
}

run "external_dataset_reference_uses_literal_connection" {
  command = plan

  variables {
    config_yaml = <<-EOT
      datasets:
        glue:
          location: aws-us-east-1
          external_dataset_reference:
            external_source: aws-glue://arn:aws:glue:us-east-1:123456789012:database/sales
            connection: projects/test-project/locations/aws-us-east-1/connections/glue
    EOT
  }

  assert {
    condition = (
      google_bigquery_dataset.this["glue"].external_dataset_reference[0].external_source == "aws-glue://arn:aws:glue:us-east-1:123456789012:database/sales" &&
      google_bigquery_dataset.this["glue"].external_dataset_reference[0].connection == "projects/test-project/locations/aws-us-east-1/connections/glue"
    )
    error_message = "external_dataset_reference was not passed through."
  }
}
