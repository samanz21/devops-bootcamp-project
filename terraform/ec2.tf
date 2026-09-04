data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }
}

data "aws_iam_instance_profile" "ssm" {
  name = "EC2-SSM-Role"
}

resource "aws_eip" "web" {
  domain = "vpc"
  tags   = { Name = "devops-web-eip" }
}

module "web_server" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name                   = "devops-web-server"
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.public_subnets[0]
  private_ip             = "10.0.0.5"
  vpc_security_group_ids = [module.sg_public.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm.name
  user_data              = file("userdata-web.sh")

  tags = { Name = "devops-web-server" }
}

resource "aws_eip_association" "web" {
  instance_id   = module.web_server.id
  allocation_id = aws_eip.web.id
}

module "ansible_controller" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name                   = "devops-ansible-controller"
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  private_ip             = "10.0.0.135"
  vpc_security_group_ids = [module.sg_private.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm.name
  user_data              = file("userdata-controller.sh")

  tags = { Name = "devops-ansible-controller" }
}

module "monitoring_server" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0"

  name                   = "devops-monitoring-server"
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.private_subnets[0]
  private_ip             = "10.0.0.136"
  vpc_security_group_ids = [module.sg_private.id]
  iam_instance_profile   = data.aws_iam_instance_profile.ssm.name
  user_data              = file("userdata-monitoring.sh")

  tags = { Name = "devops-monitoring-server" }
}