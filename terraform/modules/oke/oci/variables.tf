variable "compartment_id" {
  description = "OCID of the compartment the cluster and node pool land in."
  type        = string
}

variable "name" {
  description = "Cluster name, also the prefix for the node pool."
  type        = string
}

variable "region" {
  description = "Region identifier, used only in the kubeconfig command output."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the control plane and the node pool, for example v1.37.0."
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like v1.37.0."
  }
}

variable "vcn_id" {
  description = "OCID of the VCN the cluster lives in."
  type        = string
}

variable "endpoint_subnet_id" {
  description = "Subnet for the Kubernetes API endpoint. Must be public when endpoint_public is true."
  type        = string
}

variable "endpoint_public" {
  description = "Give the API endpoint a public IP. Lock it down with endpoint_nsg_ids."
  type        = bool
  default     = true
}

variable "endpoint_nsg_ids" {
  description = "NSGs applied to the API endpoint."
  type        = list(string)
  default     = []
}

variable "lb_subnet_ids" {
  description = "Subnets the cloud controller manager places LoadBalancer services in."
  type        = list(string)
}

variable "node_subnet_id" {
  description = "Subnet for the worker nodes."
  type        = string
}

variable "node_nsg_ids" {
  description = "NSGs applied to the worker node VNICs."
  type        = list(string)
  default     = []
}

variable "pod_subnet_id" {
  description = "Subnet for pod VNICs (VCN-native CNI)."
  type        = string
}

variable "pod_nsg_ids" {
  description = "NSGs applied to pod VNICs (VCN-native CNI)."
  type        = list(string)
  default     = []
}

variable "max_pods_per_node" {
  description = "Pods per node with the VCN-native CNI. Bounded by the shape's VNIC count; 31 fits a 4 OCPU E5."
  type        = number
  default     = 31
}

variable "services_cidr" {
  description = "ClusterIP service range. Must not overlap the VCN or any peered VCN."
  type        = string
  default     = "10.96.0.0/16"
}

variable "oidc_discovery_enabled" {
  description = "Publish the cluster's OIDC discovery document (Enhanced clusters only)."
  type        = bool
  default     = true
}

variable "node_count" {
  description = "Number of worker nodes, spread over fault_domains."
  type        = number
  default     = 3
}

variable "node_shape" {
  description = "Worker node shape."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "node_ocpus" {
  description = "OCPUs per worker node (Flex shapes)."
  type        = number
  default     = 4
}

variable "node_memory_gbs" {
  description = "Memory per worker node in GB (Flex shapes)."
  type        = number
  default     = 32
}

variable "node_boot_volume_gbs" {
  description = "Boot volume size per worker node in GB."
  type        = number
  default     = 100
}

variable "fault_domains" {
  description = "Fault domains the node pool spreads nodes over."
  type        = list(string)
  default     = ["FAULT-DOMAIN-1", "FAULT-DOMAIN-2", "FAULT-DOMAIN-3"]
}

variable "node_image_id" {
  description = "Node image OCID. When null the newest Oracle Linux x86_64 OKE image for kubernetes_version is used."
  type        = string
  default     = null
}

variable "freeform_tags" {
  description = "Freeform tags applied to the cluster and node pool."
  type        = map(string)
  default     = {}
}
