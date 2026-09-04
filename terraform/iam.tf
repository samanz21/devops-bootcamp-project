resource "aws_iam_policy" "ecr_pull" {
  name        = "ECR-Pull-Policy"
  description = "Allow EC2 instances to pull/push images from/to ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage"
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

resource "aws_iam_policy" "ssm_parameter_read" {
  name        = "SSM-Parameter-Read-Policy"
  description = "Allow EC2 instances to read SSM Parameter Store values"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = "arn:aws:ssm:ap-southeast-1:641379499267:parameter/devops-bootcamp-2026/tunnel-token"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_parameter_read" {
  role       = "EC2-SSM-Role"
  policy_arn = aws_iam_policy.ssm_parameter_read.arn
}