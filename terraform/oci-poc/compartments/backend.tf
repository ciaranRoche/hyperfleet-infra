# Remote state on the same GCS backend as the other stacks, under its own
# prefix, separate from the environment stack one level up. Configure with:
#   terraform init -backend-config=poc.tfbackend
terraform {
  backend "gcs" {}
}
