module "sg_public" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name   = "devops-sg-public"
  vpc_id = module.vpc.vpc_id

  ingress_rules = {
    http = {
      cidr_ipv4   = "0.0.0.0/0"
      ip_protocol = "tcp"
      from_port   = 80
      to_port     = 80
    }
    ssh_vpc = {
      cidr_ipv4   = "10.0.0.0/24"
      ip_protocol = "tcp"
      from_port   = 22
      to_port     = 22
    }
  }

  egress_rules = {
    all = {
      cidr_ipv4   = "0.0.0.0/0"
      ip_protocol = "-1"
    }
  }

  tags = { Name = "devops-sg-public" }
}

module "sg_private" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name   = "devops-sg-private"
  vpc_id = module.vpc.vpc_id

  ingress_rules = {
    vpc_internal = {
      cidr_ipv4   = "10.0.0.0/24"
      ip_protocol = "-1"
    }
  }

  egress_rules = {
    all = {
      cidr_ipv4   = "0.0.0.0/0"
      ip_protocol = "-1"
    }
  }

  tags = { Name = "devops-sg-private" }
}