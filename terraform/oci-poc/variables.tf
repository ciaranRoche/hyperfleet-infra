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

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach the OKE API endpoint on 6443. Your own public address as a /32 at minimum."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "allowed_cidrs must list at least one CIDR and never 0.0.0.0/0."
  }
}

variable "service_compartment_name" {
  description = "Name of the service-side compartment. OCI reserves the plain name \"service\", so it cannot be used."
  type        = string
  default     = "service-provider"
}

variable "name_prefix" {
  description = "Prefix for every display name."
  type        = string
  default     = "hyperfleet-poc"
}

variable "service_vcn_cidr" {
  description = "CIDR of the service VCN (OKE management cluster). A /16."
  type        = string
  default     = "10.60.0.0/16"
}

variable "customer_vcn_cidrs" {
  description = "CIDR per customer VCN, keyed by customer name. Each a /16, none overlapping the service VCN or each other."
  type        = map(string)
  default = {
    "customer-a" = "10.70.0.0/16"
    "customer-b" = "10.71.0.0/16"
  }
}

variable "kubernetes_version" {
  description = "OKE Kubernetes version."
  type        = string
  default     = "v1.37.0"
}

variable "node_count" {
  description = "Worker nodes in the management cluster, spread over the three fault domains."
  type        = number
  default     = 3
}

variable "node_shape" {
  description = "Worker node shape."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per worker node."
  type        = number
  default     = 4
}

variable "node_memory_gbs" {
  description = "Memory per worker node in GB."
  type        = number
  default     = 32
}

variable "node_boot_volume_gbs" {
  description = "Boot volume per worker node in GB."
  type        = number
  default     = 100
}

variable "customer_worker_policy_verbs" {
  description = <<-EOT
    Verb and resource pairs granted to each customer's worker dynamic group in
    its own compartment. The guest cloud controller manager needs load
    balancers, network security groups and instance and VNIC reads; the block
    volume CSI driver needs volumes and attachments.
  EOT
  type        = list(string)
  default = [
    "manage load-balancers",
    "manage network-security-groups",
    "manage virtual-network-family",
    "manage volume-family",
    "manage instance-family",
  ]
}
