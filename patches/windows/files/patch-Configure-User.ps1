# Patched into Configure-User.ps1

# Check if CloudWatch agent is already installed
if (-not (Test-Path "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1")) {
    Write-Host "Installing CloudWatch agent..."
    
    # Get the AWS region from environment variable
    $region = $env:AWS_DEFAULT_REGION
    if (-not $region) {
        Write-Warning "AWS_DEFAULT_REGION not set, using us-east-1 as default"
        $region = "us-east-1"
    }
    
    # Download and install CloudWatch agent
    $cloudwatchUrl = "https://amazoncloudwatch-agent.s3.amazonaws.com/windows/amd64/latest/amazon-cloudwatch-agent.msi"
    
    try {
        $output = & msiexec.exe /i $cloudwatchUrl | Write-Verbose
        Write-Host "CloudWatch agent installation completed successfully"
    }
    catch {
        Write-Warning "Failed to install CloudWatch agent: $($_.Exception.Message)"
    }
}
