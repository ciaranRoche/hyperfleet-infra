variable "compartment_id" {
  description = "OCID of the compartment the cluster is created in"
  type        = string
}

variable "cluster_name" {
  description = "Display name for the OKE cluster"
  type        = string
}

variable "vcn_id" {
  description = "OCID of the VCN to place the cluster in"
  type        = string
}

variable "endpoint_subnet_id" {
  description = "Subnet OCID for the Kubernetes API endpoint (public subnet for a public endpoint)"
  type        = string
}

variable "lb_subnet_id" {
  description = "Subnet OCID OKE uses for Kubernetes services of type LoadBalancer"
  type        = string
}

variable "node_subnet_id" {
  description = "Subnet OCID for worker nodes (private subnet)"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version (e.g. v1.31.1). Empty string selects the latest supported by OKE"
  type        = string
  default     = ""
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 3
}

variable "node_shape" {
  description = "Compute shape for worker nodes"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per worker node (flex shapes)"
  type        = number
  default     = 2
}

variable "node_memory_gbs" {
  description = "Memory in GB per worker node (flex shapes)"
  type        = number
  default     = 16
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
