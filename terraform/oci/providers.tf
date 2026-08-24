# Defaults to session-token auth (browser SSO via `oci session authenticate
# --region us-sanjose-1`, profile DEFAULT, ~1h lifetime). For non-interactive
# use, upload an API key to your user, add a matching profile, and set
# TF_VAR_oci_auth=APIKey TF_VAR_oci_profile=<profile> (see README).
provider "oci" {
  auth                = var.oci_auth
  config_file_profile = var.oci_profile
  region              = var.oci_region
}
