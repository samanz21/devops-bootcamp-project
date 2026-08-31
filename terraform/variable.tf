variable "az" {
  description = "Availability Zone"
  type        = string
  default     = "ap-southeast-1a"
}

variable "ami_owner" {
  description = "Owner ID for Ubuntu AMI"
  type        = string
  default     = "099720109477"
}

variable "ami_name_pattern" {
  description = "AMI name pattern"
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}