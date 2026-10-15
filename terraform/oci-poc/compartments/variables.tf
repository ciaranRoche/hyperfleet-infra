variable "tenancy_ocid" {
  description = "OCID of the rhelcert tenancy."
  type        = string
}

variable "region" {
  description = "OCI region to create resources in."
  type        = string
  default     = "us-sanjose-1"
}

variable "oci_auth" {
  description = "OCI provider auth mode: \"ApiKey\" (durable) or \"SecurityToken\" (browser SSO session, via `oci session authenticate`)."
  type        = string
  default     = "ApiKey"

  validation {
    condition     = contains(["ApiKey", "SecurityToken"], var.oci_auth)
    error_message = "oci_auth must be \"ApiKey\" or \"SecurityToken\"."
  }
}

variable "oci_config_file_profile" {
  description = "Profile name in ~/.oci/config to use when oci_auth = \"SecurityToken\"."
  type        = string
  default     = "DEFAULT"
}

variable "oci_user_ocid" {
  description = "User OCID, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}

variable "oci_fingerprint" {
  description = "API key fingerprint, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}

variable "oci_private_key_path" {
  description = "Path to the API private key, when oci_auth = \"ApiKey\"."
  type        = string
  default     = null
}


variable "poc_compartment_id" {
  description = <<-EOT
    OCID of the hyperfleet-poc compartment. The service and customer
    compartments are created as siblings directly under it, never nested in
    each other: OCI policies inherit downwards, so a customer compartment
    inside the service compartment would be covered by every service grant and
    the boundary would prove nothing.
  EOT
  type        = string

  validation {
    condition     = startswith(var.poc_compartment_id, "ocid1.compartment.")
    error_message = "poc_compartment_id must be a compartment OCID."
  }
}

variable "owner" {
  description = "Kerberos id of the person running this stack, applied as the `owner` tag."
  type        = string
}

variable "service_compartment_name" {
  description = "Name of the service-side compartment. OCI reserves the plain name \"service\", so it cannot be used."
  type        = string
  default     = "service-provider"
}

variable "customer_names" {
  description = "Customer compartments to create. Must match the keys of customer_vcn_cidrs in the environment stack."
  type        = list(string)
  default     = ["customer-a", "customer-b"]
}
