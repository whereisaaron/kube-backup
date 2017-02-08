# Sample kube-backup deployment

Before using this example inspect what it does and adjust as required.
It will create a `kube-backup` namespace with RBAC roles and `kube-backup` Secret

## Install steps

Set the required environment variables:
- AWS_ACCESS_KEY_ID
- AWS_SECRET_ACCESS_KEY
- SLACK_WEBHOOK

Optionally set the environment variables:
- S3_BUCKET

Run the `Deploy.sh` script.

*The SLACK_WEBHOOK should really be optional, you can remove it or set it to blank if you wish*
