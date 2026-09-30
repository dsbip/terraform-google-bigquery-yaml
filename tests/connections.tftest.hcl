# Connections of every type, secrets and connection IAM.

mock_provider "google" {}

variables {
  project_id = "test-project"
  secrets = {
    db_password        = "s3cret"
    alloydb_password   = "an0ther"
    aws_secret_key_val = "unused"
  }
}

run "connection_types" {
  command = plan

  variables {
    config_yaml = <<-EOT
      defaults:
        location: EU
      connections:
        lake:
          friendly_name: Lake
          description: BigLake access
          cloud_resource:
        pg:
          location: europe-west1
          connection_id: orders_pg
          cloud_sql:
            instance_id: test-project:europe-west1:orders
            database: orders
            type: POSTGRES
            credential:
              username: reader
              password_secret: db_password
        spanner:
          cloud_spanner:
            database: projects/test-project/instances/i/databases/d
            use_parallelism: true
            use_data_boost: true
            max_parallelism: 4
            database_role: reader
        aws:
          location: aws-us-east-1
          aws:
            access_role:
              iam_role_id: arn:aws:iam::123456789012:role/omni
        azure:
          location: azure-eastus2
          azure:
            customer_tenant_id: tenant
            federated_application_client_id: client
        spark:
          spark:
            metastore_service_config:
              metastore_service: projects/test-project/locations/europe-west1/services/hms
            spark_history_server_config:
              dataproc_cluster: projects/test-project/regions/europe-west1/clusters/history
        spark_plain:
          spark: {}
        alloydb:
          kms_key_name: projects/p/locations/eu/keyRings/r/cryptoKeys/k
          configuration:
            connector_id: google-alloydb
            asset:
              database: inventory
              google_cloud_resource: //alloydb.googleapis.com/projects/test-project/locations/europe-west1/clusters/c/instances/i
            authentication:
              username_password:
                username: bq
                password_secret: alloydb_password
            network:
              private_service_connect:
                network_attachment: projects/test-project/regions/europe-west1/networkAttachments/na
    EOT
  }

  assert {
    condition = (
      length(google_bigquery_connection.this["lake"].cloud_resource) == 1 &&
      google_bigquery_connection.this["lake"].connection_id == "lake" &&
      google_bigquery_connection.this["lake"].location == "EU" &&
      google_bigquery_connection.this["lake"].friendly_name == "Lake"
    )
    error_message = "A bare cloud_resource key should create a cloud_resource connection in the default location."
  }
  assert {
    condition = (
      google_bigquery_connection.this["pg"].connection_id == "orders_pg" &&
      google_bigquery_connection.this["pg"].location == "europe-west1" &&
      google_bigquery_connection.this["pg"].cloud_sql[0].type == "POSTGRES" &&
      google_bigquery_connection.this["pg"].cloud_sql[0].credential[0].username == "reader" &&
      nonsensitive(google_bigquery_connection.this["pg"].cloud_sql[0].credential[0].password) == "s3cret"
    )
    error_message = "The Cloud SQL connection or its secret is wrong."
  }
  assert {
    condition = (
      google_bigquery_connection.this["spanner"].cloud_spanner[0].use_data_boost == true &&
      google_bigquery_connection.this["spanner"].cloud_spanner[0].max_parallelism == 4 &&
      google_bigquery_connection.this["spanner"].cloud_spanner[0].database_role == "reader"
    )
    error_message = "The Spanner connection is wrong."
  }
  assert {
    condition = (
      google_bigquery_connection.this["aws"].aws[0].access_role[0].iam_role_id == "arn:aws:iam::123456789012:role/omni" &&
      google_bigquery_connection.this["azure"].azure[0].customer_tenant_id == "tenant" &&
      google_bigquery_connection.this["azure"].azure[0].federated_application_client_id == "client"
    )
    error_message = "The AWS or Azure connection is wrong."
  }
  assert {
    condition = (
      google_bigquery_connection.this["spark"].spark[0].metastore_service_config[0].metastore_service == "projects/test-project/locations/europe-west1/services/hms" &&
      google_bigquery_connection.this["spark"].spark[0].spark_history_server_config[0].dataproc_cluster == "projects/test-project/regions/europe-west1/clusters/history" &&
      length(google_bigquery_connection.this["spark_plain"].spark) == 1 &&
      length(google_bigquery_connection.this["spark_plain"].spark[0].metastore_service_config) == 0
    )
    error_message = "The Spark connections are wrong."
  }
  assert {
    condition = (
      google_bigquery_connection.this["alloydb"].configuration[0].connector_id == "google-alloydb" &&
      google_bigquery_connection.this["alloydb"].configuration[0].asset[0].database == "inventory" &&
      google_bigquery_connection.this["alloydb"].configuration[0].authentication[0].username_password[0].username == "bq" &&
      nonsensitive(google_bigquery_connection.this["alloydb"].configuration[0].authentication[0].username_password[0].password[0].plaintext) == "an0ther" &&
      google_bigquery_connection.this["alloydb"].configuration[0].network[0].private_service_connect[0].network_attachment == "projects/test-project/regions/europe-west1/networkAttachments/na" &&
      google_bigquery_connection.this["alloydb"].kms_key_name == "projects/p/locations/eu/keyRings/r/cryptoKeys/k"
    )
    error_message = "The connector configuration is wrong."
  }
  assert {
    condition = alltrue([
      for k, c in google_bigquery_connection.this :
      length(c.cloud_resource) + length(c.cloud_sql) + length(c.aws) + length(c.azure) + length(c.cloud_spanner) + length(c.spark) + length(c.configuration) == 1
    ])
    error_message = "Every connection must have exactly one type block."
  }
}

run "connection_iam" {
  command = plan

  variables {
    config_yaml = <<-EOT
      connections:
        lake:
          location: US
          cloud_resource: {}
          iam:
            - role: roles/bigquery.connectionUser
              members: [group:analysts@example.com, serviceAccount:sa@test-project.iam.gserviceaccount.com]
    EOT
  }

  assert {
    condition = (
      length(google_bigquery_connection_iam_member.this) == 2 &&
      google_bigquery_connection_iam_member.this["lake|roles/bigquery.connectionUser|group:analysts@example.com"].location == "US" &&
      google_bigquery_connection_iam_member.this["lake|roles/bigquery.connectionUser|group:analysts@example.com"].connection_id == "lake"
    )
    error_message = "Connection IAM members are wrong."
  }
}

run "connection_outputs" {
  command = apply

  variables {
    config_yaml = "connections:\n  lake:\n    location: US\n    cloud_resource: {}\n"
  }

  assert {
    condition     = output.connections["lake"].connection_id == "lake" && output.connections["lake"].location == "US"
    error_message = "The connections output is wrong."
  }
  assert {
    condition     = output.connections["lake"].service_account_id == google_bigquery_connection.this["lake"].cloud_resource[0].service_account_id
    error_message = "service_account_id should come from the cloud_resource block."
  }
}
