resource "aws_ecr_repository" "app" {
  name = var.project

  # Each image is tagged with the git commit SHA and never overwritten, so the
  # running task traces back to exactly one commit.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning, free. Findings are printed by the deploy workflow, not gated.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Lets terraform destroy remove the repository with its images in it, so
  # teardown leaves nothing behind (docs/vision.md section 8).
  force_delete = true
}
