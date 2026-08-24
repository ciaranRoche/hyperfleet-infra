# Same GCS backend as the GKE stacks; state lives alongside the team's other
# Terraform state. Usage: terraform init -backend-config=../envs/oke/<env>.tfbackend
# Local-only iteration: terraform init -backend=false (validate) or delete this
# block on a scratch copy.
terraform {
  backend "gcs" {
    # bucket and prefix are set via -backend-config during init
  }
}
