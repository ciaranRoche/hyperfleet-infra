variable "compartment_id" {
  description = "OCID of the compartment the VCN and everything in it lands in."
  type        = string
}

variable "name" {
  description = "Display name of the VCN, also the prefix for its gateways and route tables."
  type        = string
}

variable "cidr" {
  description = "IPv4 CIDR block of the VCN."
  type        = string
}

variable "dns_label" {
  description = "VCN DNS label (letters and digits only, up to 15 characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,14}$", var.dns_label))
    error_message = "dns_label must start with a letter and contain only lowercase letters and digits, up to 15 characters."
  }
}

variable "subnets" {
  description = <<-EOT
    Subnets to create, keyed by a short name that is also used in outputs.
    `public` subnets allow public IPs and route 0.0.0.0/0 to the internet
    gateway; private subnets forbid public IPs and route 0.0.0.0/0 to the NAT
    gateway, Oracle services to the service gateway and `drg_routes` to the DRG.
    `dns_label` defaults to the key with hyphens removed.
  EOT
  type = map(object({
    cidr      = string
    public    = bool
    dns_label = optional(string)
  }))
}

variable "create_internet_gateway" {
  description = "Create an internet gateway and the public route table. Required when any subnet is public."
  type        = bool
  default     = true
}

variable "attach_drg" {
  description = "Attach this VCN to the DRG in drg_id and route drg_routes to it. A separate flag because the DRG OCID is usually unknown at plan time and cannot drive a count."
  type        = bool
  default     = false
}

variable "drg_id" {
  description = "OCID of the DRG to attach to when attach_drg is true."
  type        = string
  default     = null
}

variable "drg_route_table_id" {
  description = "DRG route table assigned to this VCN's attachment. Null uses the DRG's default for VCN attachments."
  type        = string
  default     = null
}

variable "drg_routes" {
  description = "CIDRs that private subnets route to the DRG. Ignored when drg_id is null."
  type        = list(string)
  default     = []
}

variable "freeform_tags" {
  description = "Freeform tags applied to every resource in the module."
  type        = map(string)
  default     = {}
}
