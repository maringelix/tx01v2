output "repository_urls" {
  description = "Repository URL by repository name."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  description = "Repository ARN by repository name."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.arn }
}
