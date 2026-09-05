# Auto-updates to the new EIP on every terraform apply after destroy/redeploy.
# API token stored in SSM Parameter Store (same pattern as tunnel-token).
data "aws_ssm_parameter" "cf_dns_token" {
  name            = "/devops-bootcamp-2026/cloudflare-dns-token"
  with_decryption = true
}

provider "cloudflare" {
  api_token = data.aws_ssm_parameter.cf_dns_token.value
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for luqmansyakir.com (dashboard -> domain -> Overview -> Zone ID)"
  type        = string
  default     = "36ecd604337b4e60b2cd6e1a2ab170fb"
}

resource "cloudflare_dns_record" "web" {
  zone_id = var.cloudflare_zone_id
  name    = "web.luqmansyakir.com"
  type    = "A"
  content = aws_eip.web.public_ip
  proxied = true
  ttl     = 1
}
