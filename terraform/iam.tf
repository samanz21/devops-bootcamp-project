resource "aws_iam_policy" "ecr_pull" {
  name        = "ECR-Pull-Policy"
  description = "Allow EC2 instances to pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_pull" {
  role       = "EC2-SSM-Role"
  policy_arn = aws_iam_policy.ecr_pull.arn
}