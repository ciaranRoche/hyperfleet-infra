# Remote state on the same GCS backend as the other stacks (see
# terraform/README.md), under its own prefix. Configure with:
#   terraform init -backend-config=poc.tfbackend
terraform {
  backend "gcs" {}
}
