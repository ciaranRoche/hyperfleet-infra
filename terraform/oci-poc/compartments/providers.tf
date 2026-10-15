# Supports two auth modes, matching whatever the operator already has set up
# via the oci CLI:
#   - auth = "ApiKey" (default): durable API key, reads fingerprint/private_key
#     from var.oci_fingerprint / var.oci_private_key_path.
#   - auth = "SecurityToken": browser SSO session token created via
#     `oci session authenticate`, reads var.oci_config_file_profile.
provider "oci" {
  auth                = var.oci_auth
  tenancy_ocid        = var.tenancy_ocid
  region              = var.region
  config_file_profile = var.oci_auth == "SecurityToken" ? var.oci_config_file_profile : null
  user_ocid           = var.oci_auth == "ApiKey" ? var.oci_user_ocid : null
  fingerprint         = var.oci_auth == "ApiKey" ? var.oci_fingerprint : null
  private_key_path    = var.oci_auth == "ApiKey" ? var.oci_private_key_path : null
}
