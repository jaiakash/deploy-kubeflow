# Remote state stored in OCI Object Storage (S3-compatible API).
# The bucket must exist before running `terraform init`.
# Create it manually in the OCI Console or via `oci os bucket create`.
terraform {
  backend "s3" {
    # OCI Object Storage S3-compatible endpoint — region-specific
    # Format: https://<namespace>.compat.objectstorage.<region>.oraclecloud.com
    endpoint = "https://<namespace>.compat.objectstorage.<region>.oraclecloud.com"

    bucket = "terraform-state-docs-agent"
    key    = "docs-agent/terraform.tfstate"
    region = "us-ashburn-1" # Change to your OCI region

    # OCI does not use AWS-style access key auth the same way,
    # but the S3-compat layer accepts Customer Secret Keys.
    # Set these via env vars:
    #   AWS_ACCESS_KEY_ID     = OCI Customer Secret Key ID
    #   AWS_SECRET_ACCESS_KEY = OCI Customer Secret Key value
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
