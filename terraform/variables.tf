variable "do_token" {
  description = "DigitalOcean API token"
  sensitive   = true
}

variable "cluster_name" {
  description = "Name of the DOKS cluster"
  type        = string
}

variable "region" {
  description = "DigitalOcean region (e.g. nyc3, sfo3)"
  type        = string
  default     = "nyc3"
}

variable "k8s_version" {
  description = "Kubernetes version slug (find with: doctl kubernetes options versions)"
  type        = string
}

variable "node_size" {
  description = "Droplet size for worker nodes (e.g. s-2vcpu-4gb)"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 2
}
