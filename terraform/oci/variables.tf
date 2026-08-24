# =============================================================================
# OCI connection
# =============================================================================
variable "oci_region" {
  description = "OCI region"
  type        = string
  default     = "us-sanjose-1"
}

variable "oci_profile" {
  description = "Profile in ~/.oci/config to use"
  type        = string
  default     = "DEFAULT"
}

variable "oci_auth" {
  description = "Provider auth method: SecurityToken (browser SSO session, the default) or APIKey (durable, needs an API key uploaded to your user and a matching profile)"
  type        = string
  default     = "SecurityToken"

  validation {
    condition     = contains(["SecurityToken", "APIKey"], var.oci_auth)
    error_message = "oci_auth must be SecurityToken or APIKey"
  }
}

variable "compartment_id" {
  description = "OCID of the compartment ALL resources in this stack are created in. Never a compartment someone did not agree to; see the OCI team guide."
  type        = string
}

# =============================================================================
# Common
# =============================================================================
variable "owner" {
  description = "Kerberos of the person responsible for these resources (tagging convention)"
  type        = string
}

variable "name_prefix" {
  description = "Prefix for resource display names"
  type        = string
  default     = "hyperfleet-poc"
}

# =============================================================================
# Network
# =============================================================================
variable "vcn_cidr" {
  description = "VCN CIDR. 10.20/16 avoids the demo VCNs (10.0/16, 10.1/16) and GCP dev ranges (10.100-102/16)"
  type        = string
  default     = "10.20.0.0/16"
}

# =============================================================================
# Cluster
# =============================================================================
variable "kubernetes_version" {
  description = "OKE Kubernetes version; empty selects latest"
  type        = string
  default     = ""
}

variable "node_count" {
  description = "Worker node count"
  type        = number
  default     = 3
}

variable "node_shape" {
  description = "Worker node shape"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per node"
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory (GB) per node"
  type        = number
  default     = 16
}

# =============================================================================
# Registry and DNS
# =============================================================================
variable "registry_repo_names" {
  description = "Container repository names to create (repo paths under the tenancy namespace)"
  type        = list(string)
  default     = ["hyperfleet-poc/scratch"]
}

variable "dns_zone_name" {
  description = "Public DNS zone to create (empty string skips zone creation; a zone is only useful with a delegatable domain)"
  type        = string
  default     = ""
}
