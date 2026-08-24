variable "compartment_id" {
  description = "OCID of the compartment the VCN and subnets are created in"
  type        = string
}

variable "vcn_name" {
  description = "Display name for the VCN"
  type        = string
}

variable "vcn_cidr" {
  description = "CIDR block for the VCN"
  type        = string
  default     = "10.20.0.0/16"
}

variable "dns_label" {
  description = "DNS label for the VCN (alphanumeric, max 15 chars)"
  type        = string
  default     = "hyperfleetpoc"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (LBs, OKE API endpoint)"
  type        = string
  default     = "10.20.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (worker nodes)"
  type        = string
  default     = "10.20.1.0/24"
}

variable "freeform_tags" {
  description = "Freeform tags applied to all resources"
  type        = map(string)
  default     = {}
}
