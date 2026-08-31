resource "aws_ecr_repository" "app" {
  name                 = "devops-ship-app"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = { Name = "devops-ship-app" }
}