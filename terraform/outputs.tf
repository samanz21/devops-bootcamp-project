output "web_public_ip" {
  value = aws_eip.web.public_ip
}

output "web_private_ip" {
  value = module.web_server.private_ip
}

output "ansible_private_ip" {
  value = module.ansible_controller.private_ip
}

output "monitoring_private_ip" {
  value = module.monitoring_server.private_ip
}

output "ssm_web" {
  value = "aws ssm start-session --target ${module.web_server.id}"
}

output "ssm_ansible" {
  value = "aws ssm start-session --target ${module.ansible_controller.id}"
}

output "ssm_monitoring" {
  value = "aws ssm start-session --target ${module.monitoring_server.id}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_id" {
  value = module.vpc.public_subnets[0]
}

output "private_subnet_id" {
  value = module.vpc.private_subnets[0]
}

output "sg_public_id" {
  value = module.sg_public.id
}

output "sg_private_id" {
  value = module.sg_private.id
}