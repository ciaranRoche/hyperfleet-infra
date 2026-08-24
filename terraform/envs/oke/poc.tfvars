# OCI POC environment
# Everything lands in the hyperfleet-poc compartment:
# rhelcert / HyperFleet / hyperfleet-poc
compartment_id = "ocid1.compartment.oc1..aaaaaaaaz57fcqgpzz3nagwazbfh5swqmnkpusst7feuqpnllbletmexteqa"

owner       = "croche"
name_prefix = "hyperfleet-poc"
oci_region  = "us-sanjose-1"

node_count      = 3
node_ocpus      = 2
node_memory_gbs = 16

registry_repo_names = ["hyperfleet-poc/scratch"]

# No delegatable domain yet, so zone creation is skipped
dns_zone_name = ""
