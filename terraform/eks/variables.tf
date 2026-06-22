variable "region" {
  default = "ap-southeast-1"
}

variable "cluster_name" {
  default = "my-gitops-cluster"
}

variable "node_instance_type" {
  default = "t3.micro" # Free Tier: 750 hrs/month (12 months)
}

variable "node_desired" {
  default = 1
}

variable "node_min" {
  default = 1
}

variable "node_max" {
  default = 1
}