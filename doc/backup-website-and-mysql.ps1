#!/bin/powershell
$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

#
# Backup MySQL database and website files
# - Use a synchronised timestamp so backups go into the same S3 directory
# - Use randomised deployment names in case any old/stuck deployments exist
#

$Timestamp = $(Get-Date -f yyyyMMdd-hhmm)
function Run-Name () { 
 'kb-task-' + -join (1..4 | %{ [char[]](0..127) -cmatch '[a-z0-9]' | Get-Random })
}
#$ExtraOpts = '--dry-run'

# The '--attach --rm' allows us to block until completion, you could remove that not wait for completion
$Command = 'kubectl run --attach --rm --quiet --restart=Never --image=whereisaaron/kube-backup:0.1.2 --namespace=kube-backup'

Invoke-Expression "$Command $(Run-Name) -- $ExtraOpts --task=backup-mysql-exec --timestamp=$Timestamp --namespace=default '--selector=app=myapp,env=dev,component=mysql'"
if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }

Invoke-Expression "$Command $(Run-Name) -- $ExtraOpts --task=backup-files-exec --timestamp=$Timestamp --namespace=default '--selector=app=myapp,env=dev,component=website' --files-path=/var/www/assets --backup-name=assets"
if ($LASTEXITCODE -ne 0) { Exit $LASTEXITCODE }