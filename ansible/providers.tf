terraform {
  required_version = ">= 1.15"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
  }

  backend "s3" {
    bucket       = "devops-bootcamp-terraform-luqman"
    key          = "ansible/terraform.tfstate"
    region       = "ap-southeast-1"
    use_lockfile = true
  }
}

data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "devops-bootcamp-terraform-luqman"
    key    = "terraform/terraform.tfstate"
    region = "ap-southeast-1"
  }
}