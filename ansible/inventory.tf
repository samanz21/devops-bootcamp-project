resource "local_file" "inventory" {
  filename = "inventory.ini"
  content = templatefile("inventory.ini.tftpl", {
    web_ip        = data.terraform_remote_state.infra.outputs.web_private_ip
    monitoring_ip = data.terraform_remote_state.infra.outputs.monitoring_private_ip
  })
}