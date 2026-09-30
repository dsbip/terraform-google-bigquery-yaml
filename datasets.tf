# -----------------------------------------------------------------------------
# Datasets
# -----------------------------------------------------------------------------

locals {
  # Dataset settings with explicit nulls removed; a bare `sales:` becomes {}.
  datasets_raw = {
    for k, v in local.datasets_input : k => { for kk, vv in try(merge({}, v), {}) : kk => vv if vv != null }
  }

  datasets_merged = {
    for k, raw in local.datasets_raw : k => merge(local.builtin_defaults.datasets, local.type_defaults.datasets, raw)
  }

  datasets = {
    for k, m in local.datasets_merged : k => {
      path                            = "datasets.${k}"
      create                          = try(tobool(m.create), true)
      project                         = try(tostring(m.project_id), local.project_id)
      dataset_id                      = try(tostring(m.dataset_id), k)
      location                        = try(tostring(m.location), local.default_location)
      friendly_name                   = try(m.friendly_name, null)
      description                     = try(m.description, null)
      labels                          = try(merge(local.default_labels, try(local.type_defaults.datasets.labels, {}), try(local.datasets_raw[k].labels, {})), local.default_labels)
      default_table_expiration_ms     = try(m.default_table_expiration_ms, null)
      default_partition_expiration_ms = try(m.default_partition_expiration_ms, null)
      delete_contents_on_destroy      = try(m.delete_contents_on_destroy, null)
      deletion_policy                 = try(m.deletion_policy, null)
      is_case_insensitive             = try(m.is_case_insensitive, null)
      default_collation               = try(m.default_collation, null)
      max_time_travel_hours           = try(tostring(m.max_time_travel_hours), null)
      storage_billing_model           = try(m.storage_billing_model, null)
      resource_tags                   = try(m.resource_tags, null)

      default_encryption_configuration = [
        for c in try([merge({}, m.default_encryption_configuration)], []) : {
          kms_key_name = try(c.kms_key_name, null)
        }
      ]
      external_dataset_reference = [
        for c in try([merge({}, m.external_dataset_reference)], []) : {
          external_source = try(c.external_source, null)
          connection      = try(c.connection, null)
        }
      ]
      external_catalog_dataset_options = [
        for c in try([merge({}, m.external_catalog_dataset_options)], []) : {
          default_storage_location_uri = try(c.default_storage_location_uri, null)
          parameters                   = try(c.parameters, null)
        }
      ]

      # defaults.datasets.access is prepended to (not replaced by) the dataset's own list.
      access = concat(
        try(concat(local.type_defaults.datasets.access, []), []),
        try(concat(local.datasets_raw[k].access, []), []),
      )
      authorized_views    = try(concat(m.authorized_views, []), [])
      authorized_datasets = try(concat(m.authorized_datasets, []), [])
      authorized_routines = try(concat(m.authorized_routines, []), [])
    }
  }
}

resource "google_bigquery_dataset" "this" {
  for_each = { for k, d in local.datasets : k => d if d.create && local.config_valid }

  project                         = each.value.project
  dataset_id                      = each.value.dataset_id
  location                        = each.value.location
  friendly_name                   = each.value.friendly_name
  description                     = each.value.description
  labels                          = each.value.labels
  default_table_expiration_ms     = each.value.default_table_expiration_ms
  default_partition_expiration_ms = each.value.default_partition_expiration_ms
  delete_contents_on_destroy      = each.value.delete_contents_on_destroy
  deletion_policy                 = each.value.deletion_policy
  is_case_insensitive             = each.value.is_case_insensitive
  default_collation               = each.value.default_collation
  max_time_travel_hours           = each.value.max_time_travel_hours
  storage_billing_model           = each.value.storage_billing_model
  resource_tags                   = each.value.resource_tags

  dynamic "default_encryption_configuration" {
    for_each = each.value.default_encryption_configuration
    content {
      kms_key_name = default_encryption_configuration.value.kms_key_name
    }
  }

  dynamic "external_dataset_reference" {
    for_each = each.value.external_dataset_reference
    content {
      external_source = external_dataset_reference.value.external_source
      connection      = try(google_bigquery_connection.this[external_dataset_reference.value.connection].name, external_dataset_reference.value.connection)
    }
  }

  dynamic "external_catalog_dataset_options" {
    for_each = each.value.external_catalog_dataset_options
    content {
      default_storage_location_uri = external_catalog_dataset_options.value.default_storage_location_uri
      parameters                   = external_catalog_dataset_options.value.parameters
    }
  }

  # No access blocks here: every grant is a google_bigquery_dataset_access
  # resource, which is non-authoritative and compatible with authorized views.
  depends_on = [terraform_data.validation]
}

# -----------------------------------------------------------------------------
# Dataset access grants (datasets.*.access)
# -----------------------------------------------------------------------------

locals {
  # The API stores these predefined roles as basic roles; normalising them keeps
  # "roles/bigquery.dataViewer" and "READER" from becoming two resources for
  # the same grant.
  access_basic_roles = {
    "roles/bigquery.dataOwner"  = "OWNER"
    "roles/bigquery.dataEditor" = "WRITER"
    "roles/bigquery.dataViewer" = "READER"
  }
  access_special_groups = ["projectOwners", "projectReaders", "projectWriters", "allAuthenticatedUsers"]
  access_email_prefixes = {
    user           = "user_by_email"
    serviceAccount = "user_by_email"
    group          = "group_by_email"
    domain         = "domain"
    specialGroup   = "special_group"
    iamMember      = "iam_member"
  }

  # try(coalesce(tostring(x), ""), "") turns a missing, null or non-string value
  # into "": nulls must not reach map keys or contains(), where they would make
  # the result unknown. Such entries are reported by validation.tf.
  dataset_access_list = flatten([
    for ds_key, ds in local.datasets : [
      for entry in ds.access : [
        for member in try(concat(entry.members, []), []) : {
          ds_key     = ds_key
          project    = ds.project
          dataset_id = ds.dataset_id
          role       = lookup(local.access_basic_roles, try(coalesce(tostring(entry.role), ""), ""), try(coalesce(tostring(entry.role), ""), ""))
          member     = try(coalesce(tostring(member), ""), "")
          condition  = try(merge({}, entry.condition), null)
        }
      ]
    ]
  ])

  # Grouping (...) tolerates the same grant listed twice (e.g. once in
  # defaults.datasets.access and once on the dataset); the first one wins.
  dataset_access_grouped = {
    for e in local.dataset_access_list : "${e.ds_key}|${e.role}|${e.member}" => e...
  }

  dataset_access = {
    for key, entries in local.dataset_access_grouped : key => merge(entries[0], {
      # "user:x@y.com" -> ("user", "x@y.com"); "allUsers" -> ("", "allUsers")
      member_type = (
        contains(local.access_special_groups, entries[0].member) ? "special_group" :
        length(split(":", entries[0].member)) > 1 ? lookup(local.access_email_prefixes, split(":", entries[0].member)[0], "iam_member") :
        "iam_member"
      )
      member_value = (
        contains(local.access_special_groups, entries[0].member) ? entries[0].member :
        length(split(":", entries[0].member)) > 1 && contains(keys(local.access_email_prefixes), split(":", entries[0].member)[0])
        ? join(":", slice(split(":", entries[0].member), 1, length(split(":", entries[0].member))))
        : entries[0].member
      )
    })
  }
}

resource "google_bigquery_dataset_access" "access" {
  for_each = { for k, v in local.dataset_access : k => v if local.config_valid }

  project        = each.value.project
  dataset_id     = each.value.dataset_id
  role           = each.value.role
  user_by_email  = each.value.member_type == "user_by_email" ? each.value.member_value : null
  group_by_email = each.value.member_type == "group_by_email" ? each.value.member_value : null
  domain         = each.value.member_type == "domain" ? each.value.member_value : null
  special_group  = each.value.member_type == "special_group" ? each.value.member_value : null
  iam_member     = each.value.member_type == "iam_member" ? each.value.member_value : null

  dynamic "condition" {
    for_each = each.value.condition == null ? [] : [each.value.condition]
    content {
      expression  = try(condition.value.expression, null)
      title       = try(condition.value.title, null)
      description = try(condition.value.description, null)
      location    = try(condition.value.location, null)
    }
  }

  depends_on = [terraform_data.validation, google_bigquery_dataset.this]
}

# -----------------------------------------------------------------------------
# Authorized views, datasets and routines (datasets.*.authorized_*)
#
# String references are resolved in this order:
#   "dataset_key.name" matching a view/routine in this file -> its real IDs
#   "dataset_key.name" whose dataset_key is in this file  -> that dataset's IDs
#   "dataset.name"                                          -> same project as the source dataset
#   "project.dataset.name"                                  -> used as written
# -----------------------------------------------------------------------------

locals {
  # Real IDs of everything a reference can point to, keyed like the YAML.
  authorizable_view_ids = {
    for k, v in merge(local.views, local.materialized_views) : k => {
      project_id = v.project
      dataset_id = v.dataset_id
      table_id   = v.table_id
    }
  }
  authorizable_routine_ids = {
    for k, r in local.routines : k => {
      project_id = r.project
      dataset_id = r.dataset_id
      routine_id = r.routine_id
    }
  }

  # Empty list items are skipped; unresolvable references resolve to "" IDs
  # and are reported by validation.tf.
  authorized_view_list = flatten([
    for ds_key, ds in local.datasets : [
      for i, ref in ds.authorized_views : {
        ds_key     = ds_key
        ref        = ref
        index      = i
        project    = ds.project
        dataset_id = ds.dataset_id
        target = (
          !can(tostring(ref)) ? {
            project_id = try(coalesce(tostring(ref.project_id), ds.project), ds.project)
            dataset_id = try(coalesce(tostring(ref.dataset_id), ""), "")
            table_id   = try(coalesce(tostring(ref.table_id), ""), "")
          } :
          contains(keys(local.authorizable_view_ids), ref) ? local.authorizable_view_ids[ref] :
          length(split(".", ref)) == 2 ? {
            project_id = try(local.datasets[split(".", ref)[0]].project, ds.project)
            dataset_id = try(local.datasets[split(".", ref)[0]].dataset_id, split(".", ref)[0])
            table_id   = split(".", ref)[1]
          } :
          length(split(".", ref)) > 2 ? {
            project_id = join(".", slice(split(".", ref), 0, length(split(".", ref)) - 2))
            dataset_id = split(".", ref)[length(split(".", ref)) - 2]
            table_id   = split(".", ref)[length(split(".", ref)) - 1]
          } :
          { project_id = "", dataset_id = "", table_id = "" }
        )
      }
      if ref != null
    ]
  ])

  authorized_views = {
    for e in local.authorized_view_list :
    "${e.ds_key}|${try(coalesce(e.target.project_id, "-"), "-")}.${e.target.dataset_id}.${e.target.table_id}" => e...
  }

  authorized_dataset_list = flatten([
    for ds_key, ds in local.datasets : [
      for i, ref in ds.authorized_datasets : {
        ds_key     = ds_key
        ref        = ref
        index      = i
        project    = ds.project
        dataset_id = ds.dataset_id
        target = (
          !can(tostring(ref)) ? {
            project_id = try(coalesce(tostring(ref.project_id), ds.project), ds.project)
            dataset_id = try(coalesce(tostring(ref.dataset_id), ""), "")
          } :
          contains(keys(local.datasets), ref) ? {
            project_id = local.datasets[ref].project
            dataset_id = local.datasets[ref].dataset_id
          } :
          length(split(".", ref)) == 1 ? {
            project_id = ds.project
            dataset_id = ref
          } :
          {
            project_id = join(".", slice(split(".", ref), 0, length(split(".", ref)) - 1))
            dataset_id = split(".", ref)[length(split(".", ref)) - 1]
          }
        )
        target_types = try(concat(ref.target_types, []), ["VIEWS"])
      }
      if ref != null
    ]
  ])

  authorized_datasets = {
    for e in local.authorized_dataset_list :
    "${e.ds_key}|${try(coalesce(e.target.project_id, "-"), "-")}.${e.target.dataset_id}" => e...
  }

  authorized_routine_list = flatten([
    for ds_key, ds in local.datasets : [
      for i, ref in ds.authorized_routines : {
        ds_key     = ds_key
        ref        = ref
        index      = i
        project    = ds.project
        dataset_id = ds.dataset_id
        target = (
          !can(tostring(ref)) ? {
            project_id = try(coalesce(tostring(ref.project_id), ds.project), ds.project)
            dataset_id = try(coalesce(tostring(ref.dataset_id), ""), "")
            routine_id = try(coalesce(tostring(ref.routine_id), ""), "")
          } :
          contains(keys(local.authorizable_routine_ids), ref) ? local.authorizable_routine_ids[ref] :
          length(split(".", ref)) == 2 ? {
            project_id = try(local.datasets[split(".", ref)[0]].project, ds.project)
            dataset_id = try(local.datasets[split(".", ref)[0]].dataset_id, split(".", ref)[0])
            routine_id = split(".", ref)[1]
          } :
          length(split(".", ref)) > 2 ? {
            project_id = join(".", slice(split(".", ref), 0, length(split(".", ref)) - 2))
            dataset_id = split(".", ref)[length(split(".", ref)) - 2]
            routine_id = split(".", ref)[length(split(".", ref)) - 1]
          } :
          { project_id = "", dataset_id = "", routine_id = "" }
        )
      }
      if ref != null
    ]
  ])

  authorized_routines = {
    for e in local.authorized_routine_list :
    "${e.ds_key}|${try(coalesce(e.target.project_id, "-"), "-")}.${e.target.dataset_id}.${e.target.routine_id}" => e...
  }
}

resource "google_bigquery_dataset_access" "authorized_view" {
  for_each = { for k, v in local.authorized_views : k => v[0] if local.config_valid }

  project    = each.value.project
  dataset_id = each.value.dataset_id

  view {
    project_id = each.value.target.project_id
    dataset_id = each.value.target.dataset_id
    table_id   = each.value.target.table_id
  }

  # The view must exist before it can be authorized.
  depends_on = [
    terraform_data.validation,
    google_bigquery_dataset.this,
    google_bigquery_table.view,
    google_bigquery_table.materialized_view,
  ]
}

resource "google_bigquery_dataset_access" "authorized_dataset" {
  for_each = { for k, v in local.authorized_datasets : k => v[0] if local.config_valid }

  project    = each.value.project
  dataset_id = each.value.dataset_id

  dataset {
    target_types = each.value.target_types
    dataset {
      project_id = each.value.target.project_id
      dataset_id = each.value.target.dataset_id
    }
  }

  depends_on = [terraform_data.validation, google_bigquery_dataset.this]
}

resource "google_bigquery_dataset_access" "authorized_routine" {
  for_each = { for k, v in local.authorized_routines : k => v[0] if local.config_valid }

  project    = each.value.project
  dataset_id = each.value.dataset_id

  routine {
    project_id = each.value.target.project_id
    dataset_id = each.value.target.dataset_id
    routine_id = each.value.target.routine_id
  }

  depends_on = [
    terraform_data.validation,
    google_bigquery_dataset.this,
    google_bigquery_routine.this,
  ]
}
