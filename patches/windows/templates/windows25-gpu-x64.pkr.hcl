packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.8.0, < 2.0.0"
    }
  }
}

variable "ami_name" {
  type = string
}

variable "ami_description" {
  type = string
}

variable "region" {
  type = string
}

variable "ami_regions" {
  type = list(string)
}

variable "image_os" {
  type = string
}

variable "image_version" {
  type = string
}

variable "source_ami_owner" {
  type = string
}

variable "source_ami_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "volume_size" {
  type    = number
  default = 100
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "g4dn.xlarge"
}

source "amazon-ebs" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_groups                                = ["all"]
  ebs_optimized                             = true
  instance_type                             = var.instance_type
  region                                    = var.region
  subnet_id                                 = var.subnet_id
  iam_instance_profile                      = "SSMInstanceProfile"
  associate_public_ip_address               = "true"
  force_deregister                          = "true"
  force_delete_snapshot                     = "true"

  communicator   = "winrm"
  winrm_insecure = "true"
  winrm_use_ssl  = "true"
  winrm_username = "Administrator"

  user_data = <<EOF
<powershell>
Enable-PSRemoting -SkipNetworkProfileCheck -Force
winrm set winrm/config/service/auth '@{Basic="true"}'
Set-Service -Name WinRM -StartupType Automatic

$Cert = New-SelfSignedCertificate -CertstoreLocation Cert:\LocalMachine\My -DnsName "parsec-aws"
Get-ChildItem WSMan:\Localhost\Listener | Where-Object Keys -eq "Transport=HTTP" | Remove-Item -Recurse
New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $Cert.Thumbprint -Force
New-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)" -Name "Windows Remote Management (HTTPS-In)" -Profile Any -LocalPort 5986 -Protocol TCP

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Manual
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value (Get-Command powershell.exe).Path -PropertyType String -Force

$adminKeysPath = "$env:ProgramData\ssh\administrators_authorized_keys"
Add-Content -Force -Path $adminKeysPath -Value ""
icacls.exe $adminKeysPath /inheritance:r /grant Administrators:F /grant SYSTEM:F
Start-Service sshd
</powershell>
<persist>false</persist>
EOF

  ami_regions = var.ami_regions

  snapshot_groups = ["all"]

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    delete_on_termination = "true"
    encrypted             = "false"
  }

  run_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  tags = {
    creator = "RunsOn"
    contact = "ops@runs-on.com"
  }

  snapshot_tags = {
    creator = "RunsOn"
    contact = "ops@runs-on.com"
  }

  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = var.source_ami_name
      root-device-type    = "ebs"
    }
    owners      = [var.source_ami_owner]
    most_recent = true
  }
}

build {
  sources = ["source.amazon-ebs.build_ebs"]

  provisioner "powershell" {
    pause_before = "2m0s"
    scripts      = ["${path.root}/../scripts/build/Install-GPU.ps1"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    scripts = ["${path.root}/../scripts/build/Install-GPU.ps1"]
  }

  provisioner "powershell" {
    pause_before = "2m0s"
    scripts      = ["${path.root}/../scripts/build/Invoke-Cleanup.ps1"]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Disabling WinRM in the published AMI...'",
      "Set-Service -Name WinRM -StartupType Disabled",
      "Write-Host 'Scheduling WinRM shutdown so Packer does not need to reconnect after final capture starts...'",
      "$null = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', \"Start-Sleep -Seconds 15; Stop-Service -Name WinRM -Force -ErrorAction SilentlyContinue\")",
      "$OSVersion = [System.Environment]::OSVersion.Version",
      "if ($OSVersion.Major -eq 10 -and $OSVersion.Build -ge 20348) {",
      "    Write-Host 'Windows Server 2022+ detected, using EC2Launch v2'",
      "    & \"C:\\Program Files\\Amazon\\EC2Launch\\EC2Launch.exe\" reset",
      "} else {",
      "    Write-Host 'Windows Server pre-2022 detected, using EC2Launch v1'",
      "    & C:\\ProgramData\\Amazon\\EC2-Windows\\Launch\\Scripts\\InitializeInstance.ps1 -Schedule",
      "}",
      "exit 0",
    ]
  }
}
