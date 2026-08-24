output "vcn_id" {
  description = "OCID of the VCN"
  value       = module.network.vcn_id
}

output "cluster_id" {
  description = "OCID of the OKE cluster"
  value       = module.oke.cluster_id
}

output "kubernetes_version" {
  description = "Kubernetes version of the cluster"
  value       = module.oke.kubernetes_version
}

output "kubeconfig_command" {
  description = "Run this to add the cluster to your kubeconfig"
  value       = module.oke.kubeconfig_command
}

output "registry_repos" {
  description = "Created container repository names"
  value       = [for r in oci_artifacts_container_repository.this : r.display_name]
}

output "dns_zone_nameservers" {
  description = "Nameservers of the DNS zone (delegate the domain to these), empty if no zone"
  value       = var.dns_zone_name != "" ? oci_dns_zone.this[0].nameservers : []
}
