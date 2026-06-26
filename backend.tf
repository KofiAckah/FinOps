# Remote state — single S3 backend for the whole project.
#
# State is encrypted at rest and locked via S3 conditional writes
# (use_lockfile), so no DynamoDB lock table is required. The bucket is created
# once by scripts/bootstrap-backend.sh before the first `terraform init`.
terraform {
  backend "s3" {
    bucket       = "finops-tfstate-412381768295"
    key          = "finops/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}
