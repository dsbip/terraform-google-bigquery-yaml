# -----------------------------------------------------------------------------
# Connections
#
# The connection type is the one type key present on the entry (cloud_resource,
# cloud_sql, aws, azure, cloud_spanner, spark or configuration). Presence counts,
# so `cloud_resource:` and `cloud_resource: {}` are equivalent.
# Other entries (external tables, BigLake tables, remote functions, Spark
# procedures, external datasets) may reference a connection by its YAML key.
# -----------------------------------------------------------------------------

locals {
  connection_types = ["cloud_resource", "cloud_sql", "aws", "azure", "cloud_spanner", "spark", "configuration"]

  connections_input = try(merge({}, local.config.connections), {})

  # Nulls are kept here so that a bare `cloud_resource:` still selects a type.
  connections_value = { for k, v in local.connections_input : k => try(merge({}, v), {}) }

  connections_merged = {
    for k, v in local.connections_value : k => merge(
      local.builtin_defaults.connections,
      local.type_defaults.connections,
      { for kk, vv in v : kk => vv if vv != null },
    )
  }

  connections = {
    for k, m in local.connections_merged : k => {
      path            = "connections.${k}"
      project         = try(tostring(m.project_id), local.project_id)
      location        = try(tostring(m.location), local.default_location)
      connection_id   = try(tostring(m.connection_id), k)
      friendly_name   = try(m.friendly_name, null)
      description     = try(m.description, null)
      kms_key_name    = try(m.kms_key_name, null)
      deletion_policy = try(m.deletion_policy, null)
      types           = [for t in local.connection_types : t if contains(keys(local.connections_value[k]), t)]

      cloud_resource = contains(keys(local.connections_value[k]), "cloud_resource") ? [{}] : []

      cloud_sql = [
        for c in try([merge({}, m.cloud_sql)], []) : {
          instance_id     = try(c.instance_id, null)
          database        = try(c.database, null)
          type            = try(c.type, null)
          username        = try(c.credential.username, null)
          password_secret = try(c.credential.password_secret, null)
        }
      ]

      aws = [
        for c in try([merge({}, m.aws)], []) : {
          iam_role_id = try(c.access_role.iam_role_id, null)
        }
      ]

      azure = [
        for c in try([merge({}, m.azure)], []) : {
          customer_tenant_id              = try(c.customer_tenant_id, null)
          federated_application_client_id = try(c.federated_application_client_id, null)
        }
      ]

      cloud_spanner = [
        for c in try([merge({}, m.cloud_spanner)], []) : {
          database        = try(c.database, null)
          database_role   = try(c.database_role, null)
          use_parallelism = try(c.use_parallelism, null)
          use_data_boost  = try(c.use_data_boost, null)
          max_parallelism = try(c.max_parallelism, null)
        }
      ]

      spark = [
        for c in(contains(keys(local.connections_value[k]), "spark") ? [try(merge({}, local.connections_value[k].spark), {})] : []) : {
          metastore_service = try(c.metastore_service_config.metastore_service, null)
          dataproc_cluster  = try(c.spark_history_server_config.dataproc_cluster, null)
        }
      ]

      configuration = [
        for c in try([merge({}, m.configuration)], []) : {
          connector_id                = try(c.connector_id, null)
          asset_database              = try(c.asset.database, null)
          asset_google_cloud_resource = try(c.asset.google_cloud_resource, null)
          username                    = try(c.authentication.username_password.username, null)
          password_secret             = try(c.authentication.username_password.password_secret, null)
          host_port                   = try(c.endpoint.host_port, null)
          network_attachment          = try(c.network.private_service_connect.network_attachment, null)
        }
      ]

      iam = try(concat(m.iam, []), [])
    }
  }
}

resource "google_bigquery_connection" "this" {
  for_each = { for k, v in local.connections : k => v if local.config_valid }

  project         = each.value.project
  location        = each.value.location
  connection_id   = each.value.connection_id
  friendly_name   = each.value.friendly_name
  description     = each.value.description
  kms_key_name    = each.value.kms_key_name
  deletion_policy = each.value.deletion_policy

  dynamic "cloud_resource" {
    for_each = each.value.cloud_resource
    content {}
  }

  dynamic "cloud_sql" {
    for_each = each.value.cloud_sql
    content {
      instance_id = cloud_sql.value.instance_id
      database    = cloud_sql.value.database
      type        = cloud_sql.value.type
      credential {
        username = cloud_sql.value.username
        password = try(var.secrets[cloud_sql.value.password_secret], null)
      }
    }
  }

  dynamic "aws" {
    for_each = each.value.aws
    content {
      access_role {
        iam_role_id = aws.value.iam_role_id
      }
    }
  }

  dynamic "azure" {
    for_each = each.value.azure
    content {
      customer_tenant_id              = azure.value.customer_tenant_id
      federated_application_client_id = azure.value.federated_application_client_id
    }
  }

  dynamic "cloud_spanner" {
    for_each = each.value.cloud_spanner
    content {
      database        = cloud_spanner.value.database
      database_role   = cloud_spanner.value.database_role
      use_parallelism = cloud_spanner.value.use_parallelism
      use_data_boost  = cloud_spanner.value.use_data_boost
      max_parallelism = cloud_spanner.value.max_parallelism
    }
  }

  dynamic "spark" {
    for_each = each.value.spark
    content {
      dynamic "metastore_service_config" {
        for_each = spark.value.metastore_service == null ? [] : [spark.value.metastore_service]
        content {
          metastore_service = metastore_service_config.value
        }
      }
      dynamic "spark_history_server_config" {
        for_each = spark.value.dataproc_cluster == null ? [] : [spark.value.dataproc_cluster]
        content {
          dataproc_cluster = spark_history_server_config.value
        }
      }
    }
  }

  dynamic "configuration" {
    for_each = each.value.configuration
    content {
      connector_id = configuration.value.connector_id

      asset {
        database              = configuration.value.asset_database
        google_cloud_resource = configuration.value.asset_google_cloud_resource
      }

      dynamic "authentication" {
        for_each = configuration.value.username == null ? [] : [configuration.value]
        content {
          username_password {
            username = authentication.value.username
            password {
              plaintext = try(var.secrets[authentication.value.password_secret], null)
            }
          }
        }
      }

      dynamic "endpoint" {
        for_each = configuration.value.host_port == null ? [] : [configuration.value.host_port]
        content {
          host_port = endpoint.value
        }
      }

      dynamic "network" {
        for_each = configuration.value.network_attachment == null ? [] : [configuration.value.network_attachment]
        content {
          private_service_connect {
            network_attachment = network.value
          }
        }
      }
    }
  }

  depends_on = [terraform_data.validation]
}

# -----------------------------------------------------------------------------
# Connection IAM (connections.*.iam), e.g. roles/bigquery.connectionUser
# -----------------------------------------------------------------------------

locals {
  connection_iam_list = flatten([
    for k, c in local.connections : [
      for binding in c.iam : [
        for member in try(concat(binding.members, []), []) : {
          connection_key = k
          role           = try(coalesce(tostring(binding.role), ""), "")
          member         = try(coalesce(tostring(member), ""), "")
          condition      = try(merge({}, binding.condition), null)
        }
      ]
    ]
  ])

  connection_iam = {
    for e in local.connection_iam_list : "${e.connection_key}|${e.role}|${e.member}" => e...
  }
}

resource "google_bigquery_connection_iam_member" "this" {
  for_each = { for k, v in local.connection_iam : k => v[0] if local.config_valid }

  project       = google_bigquery_connection.this[each.value.connection_key].project
  location      = google_bigquery_connection.this[each.value.connection_key].location
  connection_id = google_bigquery_connection.this[each.value.connection_key].connection_id
  role          = each.value.role
  member        = each.value.member

  dynamic "condition" {
    for_each = each.value.condition == null ? [] : [each.value.condition]
    content {
      title       = try(condition.value.title, null)
      expression  = try(condition.value.expression, null)
      description = try(condition.value.description, null)
    }
  }
}
