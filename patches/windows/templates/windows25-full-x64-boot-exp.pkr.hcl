# Experiment template: minimal installs for fast boot-time iteration.
# Derived from windows25-full-x64.pkr.hcl with heavy toolchain removed.
# Usage: copy over patches/windows/templates/windows25-full-x64.pkr.hcl before build.

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.8.0, < 2.0.0"
    }
  }
}

variable "agent_tools_directory" {
  type    = string
  default = "C:\\hostedtoolcache\\windows"
}

variable "helper_script_folder" {
  type    = string
  default = "C:\\Program Files\\WindowsPowerShell\\Modules\\"
}

variable "image_folder" {
  type    = string
  default = "C:\\image"
}

variable "image_os" {
  type    = string
  default = "win25"
}

variable "image_version" {
  type    = string
  default = "dev"
}

variable "imagedata_file" {
  type    = string
  default = "C:\\imagedata.json"
}

variable "temp_dir" {
  type    = string
  default = "C:\\temp-to-delete"
}

variable "install_password" {
  type      = string
  default   = "P4ssw0rd@1234"
  sensitive = true
}

variable "install_user" {
  type    = string
  default = "installer"
}

variable "ami_name" {
  type    = string
  default = "${env("AMI_NAME")}"
}

variable "ami_description" {
  type    = string
  default = "${env("AMI_DESCRIPTION")}"
}

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "ami_regions" {
  type    = list(string)
}

variable "source_ami_owner" {
  type    = string
  default = "801119661308"
}

variable "source_ami_name" {
  type    = string
  default = "Windows_Server-2025-English-Full-Base-*"
}

variable "subnet_id" {
  type    = string
  default = "${env("SUBNET_ID")}"
}

variable "volume_size" {
  type    = number
  default = 30
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "m8i.4xlarge"
}

source "amazon-ebs" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = "${var.ami_name}"
  ami_description                           = "${var.ami_description}"
  ami_virtualization_type                   = "hvm"
  ami_groups                                = ["all"]
  ebs_optimized                             = true
  enable_nested_virtualization              = true
  instance_type                             = var.instance_type
  region                                    = "${var.region}"
  subnet_id                                 = "${var.subnet_id}"
  iam_instance_profile                      = "SSMInstanceProfile"
  associate_public_ip_address               = "true"
  force_deregister                          = "true"
  force_delete_snapshot                     = "true"

  communicator                           = "winrm"
  winrm_insecure                         = "true"
  winrm_use_ssl                          = "true"
  winrm_username                         = "Administrator"

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

  ami_regions = "${var.ami_regions}"

  snapshot_groups = ["all"]

  launch_block_device_mappings {
    device_name = "/dev/sda1"
    volume_type = "${var.volume_type}"
    volume_size = "${var.volume_size}"
    delete_on_termination = "true"
    encrypted = "false"
  }

  run_tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
  }

  tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
  }

  snapshot_tags = {
    creator     = "RunsOn"
    contact     = "ops@runs-on.com"
  }

  source_ami_filter {
    filters = {
      virtualization-type = "hvm"
      name                = "${var.source_ami_name}"
      root-device-type    = "ebs"
    }
    owners      = ["${var.source_ami_owner}"]
    most_recent = true
  }
}

build {
  sources = ["source.amazon-ebs.build_ebs"]

  provisioner "powershell" {
    inline = [
      "New-Item -Path ${var.image_folder} -ItemType Directory -Force",
      "New-Item -Path ${var.image_folder}\\assets -ItemType Directory -Force",
      "New-Item -Path ${var.image_folder}\\scripts -ItemType Directory -Force",
      "New-Item -Path ${var.image_folder}\\toolsets -ItemType Directory -Force",
      "New-Item -Path ${var.temp_dir} -ItemType Directory -Force"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}\\"
    source      = "${path.root}/../assets"
  }

  provisioner "file" {
    destination = "${var.image_folder}\\scripts\\"
    sources     = [
      "${path.root}/../scripts/docs-gen",
      "${path.root}/../scripts/helpers",
      "${path.root}/../scripts/tests"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}\\"
    source      = "${path.root}/../toolsets"
  }

  provisioner "powershell" {
    inline = [
      "Move-Item '${var.image_folder}\\assets\\post-gen' 'C:\\post-generation'",
      "Remove-Item -Recurse '${var.image_folder}\\assets'",
      "Move-Item '${var.image_folder}\\scripts\\docs-gen' '${var.image_folder}\\SoftwareReport'",
      "Move-Item '${var.image_folder}\\scripts\\helpers' '${var.helper_script_folder}\\ImageHelpers'",
      "New-Item -Type Directory -Path '${var.helper_script_folder}\\TestsHelpers\\'",
      "Move-Item '${var.image_folder}\\scripts\\tests\\Helpers.psm1' '${var.helper_script_folder}\\TestsHelpers\\TestsHelpers.psm1'",
      "Move-Item '${var.image_folder}\\scripts\\tests' '${var.image_folder}\\tests'",
      "Remove-Item -Recurse '${var.image_folder}\\scripts'",
      "Move-Item '${var.image_folder}\\toolsets\\toolset-2025.json' '${var.image_folder}\\toolset.json'",
      "Remove-Item -Recurse '${var.image_folder}\\toolsets'"
    ]
  }

  provisioner "windows-shell" {
    inline = [
      "net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes /active:yes /Y",
      "net localgroup Administrators ${var.install_user} /add",
      "winrm set winrm/config/service/auth @{Basic=\"true\"}",
      "winrm get winrm/config/service/auth"
    ]
  }

  provisioner "powershell" {
    inline = ["if (-not ((net localgroup Administrators) -contains '${var.install_user}')) { exit 1 }"]
  }

  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    inline            = ["bcdedit.exe /set TESTSIGNING ON"]
  }

  # --- EXPERIMENT: Minimal install set ---
  # Only essential: base config, Chocolatey, Git, Runner. Everything else skipped.

  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "AGENT_TOOLSDIRECTORY=${var.agent_tools_directory}", "IMAGEDATA_FILE=${var.imagedata_file}", "IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    execution_policy = "unrestricted"
    scripts          = [
      "${path.root}/../scripts/build/Configure-PowerShell.ps1",
      "${path.root}/../scripts/build/Install-PowerShellModules.ps1",
      "${path.root}/../scripts/build/Install-Chocolatey.ps1",
      "${path.root}/../scripts/build/Configure-BaseImage.ps1",
      "${path.root}/../scripts/build/Configure-ImageDataFile.ps1",
      "${path.root}/../scripts/build/Configure-SystemEnvironment.ps1",
      "${path.root}/../scripts/build/Configure-DotnetSecureChannel.ps1"
    ]
  }

  provisioner "windows-restart" {
    check_registry  = true
    restart_timeout = "15m"
  }

  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-Git.ps1",
      "${path.root}/../scripts/build/Install-GitHub-CLI.ps1",
      "${path.root}/../scripts/build/Install-PowershellCore.ps1",
      "${path.root}/../scripts/build/Install-Runner.ps1",
      "${path.root}/../scripts/build/Install-RunsOnBootstrap.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "15m"
  }

  provisioner "powershell" {
    pause_before     = "1m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Configure-Diagnostics.ps1"
    ]
  }

  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts           = [
      "${path.root}/../scripts/build/Configure-DynamicPort.ps1",
      "${path.root}/../scripts/build/Configure-GDIProcessHandleQuota.ps1",
      "${path.root}/../scripts/build/Configure-Shell.ps1",
      "${path.root}/../scripts/build/Configure-DeveloperMode.ps1"
    ]
  }

  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {if ((-not (Get-Process TiWorker.exe -ErrorAction SilentlyContinue)) -and (-not [System.Environment]::HasShutdownStarted) ) { Write-Output 'Restart complete' }}\""
    restart_timeout       = "20m"
  }

  provisioner "powershell" {
    pause_before     = "1m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Invoke-Cleanup.ps1"
    ]
  }

  provisioner "powershell" {
    inline = ["Remove-Item '${var.temp_dir}' -Recurse -Force -ErrorAction SilentlyContinue"]
  }

  provisioner "powershell" {
    environment_vars = ["INSTALL_USER=${var.install_user}"]
    scripts          = [
      "${path.root}/../scripts/build/Configure-System.ps1",
      "${path.root}/../scripts/build/Configure-User.ps1"
    ]
    skip_clean       = true
  }

  provisioner "powershell" {
    scripts = [
      "${path.root}/../custom/boot-config.ps1"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Disabling page file...'",
      "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management' -Name PagingFiles -Value @() -Force"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Preparing the final AMI service state...'",
      "Write-Host 'Disabling WinRM in the published AMI...'",
      "Set-Service -Name WinRM -StartupType Disabled",
      "Write-Host 'Scheduling WinRM shutdown so Packer does not need to reconnect after final capture starts...'",
      "$null = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', \"Start-Sleep -Seconds 15; Stop-Service -Name WinRM -Force -ErrorAction SilentlyContinue\")",
      "$OSVersion = [System.Environment]::OSVersion.Version",
      "if ($OSVersion.Major -eq 10 -and $OSVersion.Build -ge 20348) {",
      "    Write-Host 'Windows Server 2025 detected, using EC2Launch v2'",
      "    & \"C:\\Program Files\\Amazon\\EC2Launch\\EC2Launch.exe\" reset",
      "} else {",
      "    Write-Host 'Older Windows version, using EC2Launch v1'",
      "    & C:\\ProgramData\\Amazon\\EC2-Windows\\Launch\\Scripts\\InitializeInstance.ps1 -Schedule",
      "}",
      "exit 0"
    ]
  }
}
