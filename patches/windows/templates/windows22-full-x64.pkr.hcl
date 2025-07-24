packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
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
  default = "win22"
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
  default = "Windows_Server-2022-English-Full-Base-*"
}

// make sure the subnet auto-assigns public IPs
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

source "amazon-ebs" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  shutdown_behavior                         = "terminate"
  ami_name                                  = "${var.ami_name}"
  ami_description                           = "${var.ami_description}"
  ami_virtualization_type                   = "hvm"
  # make AMIs publicly accessible
  ami_groups                                = ["all"]
  ebs_optimized                             = true
  # spot_instance_types                       = ["c6a.metal", "m6a.metal", "c6i.metal", "m6i.metal", "c7i.metal-24xl", "m7i.metal-24xl"]
  instance_type                             = "m7a.large"
  region                                    = "${var.region}"
  subnet_id                                 = "${var.subnet_id}"
  associate_public_ip_address               = "true"
  force_deregister                          = "true"
  force_delete_snapshot                     = "true"

  communicator                           = "winrm"
  winrm_insecure                         = "true"
  winrm_use_ssl                          = "true"
  winrm_username                         = "Administrator"

  # https://learn.microsoft.com/en-us/windows/win32/winrm/installation-and-configuration-for-windows-remote-management
  user_data = <<EOF
<powershell>
# Configure WinRM
Enable-PSRemoting -SkipNetworkProfileCheck -Force
winrm set winrm/config/service/auth '@{Basic="true"}'
Set-Service -Name WinRM -StartupType Automatic

# Create and configure certificate
$Cert = New-SelfSignedCertificate -CertstoreLocation Cert:\LocalMachine\My -DnsName "parsec-aws"

# Remove HTTP listener and add HTTPS
Get-ChildItem WSMan:\Localhost\Listener | Where-Object Keys -eq "Transport=HTTP" | Remove-Item -Recurse
New-Item -Path WSMan:\LocalHost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $Cert.Thumbprint -Force

# Configure firewall
New-NetFirewallRule -DisplayName "Windows Remote Management (HTTPS-In)" -Name "Windows Remote Management (HTTPS-In)" -Profile Any -LocalPort 5986 -Protocol TCP

# Install sshd
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Manual
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value (Get-Command powershell.exe).Path -PropertyType String -Force

# Used to connect to the instance
$adminKeysPath = "$env:ProgramData\ssh\administrators_authorized_keys"

Add-Content -Force -Path $adminKeysPath -Value ""
# Uncomment for debugging
#Add-Content -Force -Path $adminKeysPath -Value ((New-Object System.Net.WebClient).DownloadString('http://169.254.169.254/latest/meta-data/public-keys/0/openssh-key'))
#Add-Content -Force -Path $adminKeysPath -Value ((New-Object System.Net.WebClient).DownloadString('https://github.com/crohr.keys'))

icacls.exe $adminKeysPath /inheritance:r /grant Administrators:F /grant SYSTEM:F
Start-Service sshd

# Create shutdown task that runs after 3 hours
$action = New-ScheduledTaskAction -Execute 'shutdown.exe' -Argument '/s /f /t 0'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Hours 3)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -DontStopOnIdleEnd
Register-ScheduledTask -TaskName "ShutdownAfter3Hours" -Action $action -Trigger $trigger -Settings $settings -User "System" -RunLevel Highest -Force

</powershell>
<persist>false</persist>
EOF

  ami_regions = "${var.ami_regions}"

  // make underlying snapshot public
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

  # provisioner "file" {
  #   destination = "${var.image_folder}\\"
  #   sources     = [
  #     "${path.root}/../assets",
  #     "${path.root}/../scripts",
  #     "${path.root}/../toolsets"
  #   ]
  # }

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

  // provisioner "file" {
  //   destination = "${var.image_folder}\\scripts\\docs-gen\\"
  //   source      = "${path.root}/../../../helpers/software-report-base"
  // }

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
      "Move-Item '${var.image_folder}\\toolsets\\toolset-2022.json' '${var.image_folder}\\toolset.json'",
      "Remove-Item -Recurse '${var.image_folder}\\toolsets'"
    ]
  }

  provisioner "powershell" {
    inline = [
      "net user ${var.install_user} ${var.install_password} /add /passwordchg:no /passwordreq:yes /active:yes /Y",
      "net localgroup Administrators ${var.install_user} /add", 
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

  provisioner "powershell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "AGENT_TOOLSDIRECTORY=${var.agent_tools_directory}", "IMAGEDATA_FILE=${var.imagedata_file}", "IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    execution_policy = "unrestricted"
    scripts          = [
      "${path.root}/../scripts/build/Configure-WindowsDefender.ps1",
      "${path.root}/../scripts/build/Configure-PowerShell.ps1",
      "${path.root}/../scripts/build/Install-PowerShellModules.ps1",
      "${path.root}/../scripts/build/Install-WindowsFeatures.ps1",
      "${path.root}/../scripts/build/Install-Chocolatey.ps1",
      "${path.root}/../scripts/build/Configure-BaseImage.ps1",
      "${path.root}/../scripts/build/Configure-ImageDataFile.ps1",
      "${path.root}/../scripts/build/Configure-SystemEnvironment.ps1",
      "${path.root}/../scripts/build/Configure-DotnetSecureChannel.ps1"
    ]
  }

  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {while ( (Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue).State -ne 'Enabled' ) { Start-Sleep 30; Write-Output 'InProgress' }}\""
    restart_timeout       = "20m"
    # restart_command       = "powershell \"& {(Get-WmiObject win32_operatingsystem).LastBootUpTime > C:\\ProgramData\\lastboot.txt; Restart-Computer -force}\""
    # restart_check_command = "powershell -command \"& {if ((get-content C:\\ProgramData\\lastboot.txt) -eq (Get-WmiObject win32_operatingsystem).LastBootUpTime) {Write-Output 'Sleeping for 600 seconds to wait for reboot'; start-sleep 600} else {Write-Output 'Reboot complete'}}\""
  }

  # provisioner "powershell" {
  #   inline = ["Set-Service -Name wlansvc -StartupType Manual", "if ($(Get-Service -Name wlansvc).Status -eq 'Running') { Stop-Service -Name wlansvc}"]
  # }

  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-Docker.ps1",
      "${path.root}/../scripts/build/Install-DockerWinCred.ps1",
      "${path.root}/../scripts/build/Install-DockerCompose.ps1",
      "${path.root}/../scripts/build/Install-PowershellCore.ps1",
      "${path.root}/../scripts/build/Install-WebPlatformInstaller.ps1",
      "${path.root}/../scripts/build/Install-Runner.ps1",
      "${path.root}/../scripts/build/Install-TortoiseSvn.ps1"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # provisioner "powershell" {
  #   elevated_password = "${var.install_password}"
  #   elevated_user     = "${var.install_user}"
  #   environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
  #   scripts           = [
  #     "${path.root}/../scripts/build/Install-VisualStudio.ps1",
  #     "${path.root}/../scripts/build/Install-KubernetesTools.ps1"
  #   ]
  #   valid_exit_codes  = [0, 3010]
  # }

  # provisioner "windows-restart" {
  #   check_registry  = true
  #   restart_timeout = "20m"
  # }

  provisioner "powershell" {
    pause_before     = "2m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-Wix.ps1",
      # "${path.root}/../scripts/build/Install-WDK.ps1",
      # "${path.root}/../scripts/build/Install-VSExtensions.ps1",
      "${path.root}/../scripts/build/Install-AzureCli.ps1",
      # "${path.root}/../scripts/build/Install-AzureDevOpsCli.ps1",
      "${path.root}/../scripts/build/Install-ChocolateyPackages.ps1",
      "${path.root}/../scripts/build/Install-JavaTools.ps1",
      "${path.root}/../scripts/build/Install-Kotlin.ps1",
      "${path.root}/../scripts/build/Install-OpenSSL.ps1"
    ]
  }

  provisioner "powershell" {
    execution_policy = "remotesigned"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = ["${path.root}/../scripts/build/Install-ServiceFabricSDK.ps1"]
  }

  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  provisioner "windows-shell" {
    inline = ["wmic product where \"name like '%%microsoft azure powershell%%'\" call uninstall /nointeractive"]
  }

  provisioner "powershell" {
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-ActionsCache.ps1",
      # "${path.root}/../scripts/build/Install-Ruby.ps1",
      # "${path.root}/../scripts/build/Install-PyPy.ps1",
      "${path.root}/../scripts/build/Install-Toolset.ps1",
      "${path.root}/../scripts/build/Configure-Toolset.ps1",
      "${path.root}/../scripts/build/Install-NodeJS.ps1",
      # "${path.root}/../scripts/build/Install-AndroidSDK.ps1",
      "${path.root}/../scripts/build/Install-PowershellAzModules.ps1",
      # "${path.root}/../scripts/build/Install-Pipx.ps1",
      "${path.root}/../scripts/build/Install-Git.ps1",
      "${path.root}/../scripts/build/Install-GitHub-CLI.ps1",
      # "${path.root}/../scripts/build/Install-PHP.ps1",
      # "${path.root}/../scripts/build/Install-Rust.ps1",
      "${path.root}/../scripts/build/Install-Sbt.ps1",
      # "${path.root}/../scripts/build/Install-Chrome.ps1",
      # "${path.root}/../scripts/build/Install-EdgeDriver.ps1",
      # "${path.root}/../scripts/build/Install-Firefox.ps1",
      # "${path.root}/../scripts/build/Install-Selenium.ps1",
      # "${path.root}/../scripts/build/Install-IEWebDriver.ps1",
      # "${path.root}/../scripts/build/Install-Apache.ps1",
      # "${path.root}/../scripts/build/Install-Nginx.ps1",
      "${path.root}/../scripts/build/Install-Msys2.ps1",
      "${path.root}/../scripts/build/Install-WinAppDriver.ps1",
      # "${path.root}/../scripts/build/Install-R.ps1",
      "${path.root}/../scripts/build/Install-AWSTools.ps1",
      # "${path.root}/../scripts/build/Install-DACFx.ps1",
      # "${path.root}/../scripts/build/Install-MysqlCli.ps1",
      "${path.root}/../scripts/build/Install-SQLPowerShellTools.ps1",
      "${path.root}/../scripts/build/Install-SQLOLEDBDriver.ps1",
      "${path.root}/../scripts/build/Install-DotnetSDK.ps1",
      "${path.root}/../scripts/build/Install-Mingw64.ps1",
      # "${path.root}/../scripts/build/Install-Haskell.ps1",
      # "${path.root}/../scripts/build/Install-Stack.ps1",
      # "${path.root}/../scripts/build/Install-Miniconda.ps1",
      # "${path.root}/../scripts/build/Install-AzureCosmosDbEmulator.ps1",
      # "${path.root}/../scripts/build/Install-Mercurial.ps1",
      "${path.root}/../scripts/build/Install-Zstd.ps1",
      # "${path.root}/../scripts/build/Install-NSIS.ps1",
      "${path.root}/../scripts/build/Install-Vcpkg.ps1",
      # "${path.root}/../scripts/build/Install-PostgreSQL.ps1",
      # "${path.root}/../scripts/build/Install-Bazel.ps1",
      # "${path.root}/../scripts/build/Install-AliyunCli.ps1",
      "${path.root}/../scripts/build/Install-RootCA.ps1",
      # "${path.root}/../scripts/build/Install-MongoDB.ps1",
      # "${path.root}/../scripts/build/Install-CodeQLBundle.ps1",
      "${path.root}/../scripts/build/Configure-Diagnostics.ps1"
    ]
  }

  provisioner "powershell" {
    elevated_password = "${var.install_password}"
    elevated_user     = "${var.install_user}"
    environment_vars  = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts           = [
      "${path.root}/../scripts/build/Install-WindowsUpdates.ps1",
      "${path.root}/../scripts/build/Configure-DynamicPort.ps1",
      "${path.root}/../scripts/build/Configure-GDIProcessHandleQuota.ps1",
      "${path.root}/../scripts/build/Configure-Shell.ps1",
      "${path.root}/../scripts/build/Configure-DeveloperMode.ps1",
      # "${path.root}/../scripts/build/Install-LLVM.ps1"
    ]
  }

  provisioner "windows-restart" {
    check_registry        = true
    restart_check_command = "powershell -command \"& {if ((-not (Get-Process TiWorker.exe -ErrorAction SilentlyContinue)) -and (-not [System.Environment]::HasShutdownStarted) ) { Write-Output 'Restart complete' }}\""
    restart_timeout       = "30m"
  }

  provisioner "powershell" {
    pause_before     = "2m0s"
    environment_vars = ["IMAGE_FOLDER=${var.image_folder}", "TEMP_DIR=${var.temp_dir}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-WindowsUpdatesAfterReboot.ps1",
      "${path.root}/../scripts/build/Invoke-Cleanup.ps1",
      # "${path.root}/../scripts/tests/RunAll-Tests.ps1"
    ]
  }

  // provisioner "powershell" {
  //   inline = ["if (-not (Test-Path ${var.image_folder}\\tests\\testResults.xml)) { throw '${var.image_folder}\\tests\\testResults.xml not found' }"]
  // }

  // provisioner "powershell" {
  //   environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_FOLDER=${var.image_folder}"]
  //   inline           = ["pwsh -File '${var.image_folder}\\SoftwareReport\\Generate-SoftwareReport.ps1'"]
  // }

  // provisioner "powershell" {
  //   inline = ["if (-not (Test-Path C:\\software-report.md)) { throw 'C:\\software-report.md not found' }", "if (-not (Test-Path C:\\software-report.json)) { throw 'C:\\software-report.json not found' }"]
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../Windows2022-Readme.md"
  //   direction   = "download"
  //   source      = "C:\\software-report.md"
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../software-report.json"
  //   direction   = "download"
  //   source      = "C:\\software-report.json"
  // }

  provisioner "powershell" {
    environment_vars = ["INSTALL_USER=${var.install_user}"]
    scripts          = [
      "${path.root}/../scripts/build/Install-NativeImages.ps1",
      "${path.root}/../scripts/build/Configure-System.ps1",
      "${path.root}/../scripts/build/Configure-User.ps1"
    ]
    skip_clean       = true
  }

  # added: disable page file (1GiB)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Disabling page file...'",
      "Set-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management' -Name PagingFiles -Value @() -Force"
    ]
  }

  provisioner "windows-restart" {
    restart_timeout = "20m"
  }

  # Modify the unattend.xml file before sysprep
  provisioner "powershell" {
    inline = [
      "Write-Output 'Modifying unattend.xml file...'",
      "$xmlPath = 'C:\\ProgramData\\Amazon\\EC2Launch\\sysprep\\unattend.xml'",
      "if (Test-Path $xmlPath) {",
      "    # Read the XML content as text",
      "    $content = Get-Content $xmlPath -Raw",
      "    # Set PersistAllDeviceInstalls to false",
      "    if ($content -match '<PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>') {",
      "        $content = $content -replace '<PersistAllDeviceInstalls>true</PersistAllDeviceInstalls>', '<PersistAllDeviceInstalls>false</PersistAllDeviceInstalls>'",
      "        Write-Output 'Set PersistAllDeviceInstalls to false'",
      "    }",
      # "    # Remove the entire RunSynchronous section",
      # "    $pattern = '<RunSynchronous>[\\s\\S]*?</RunSynchronous>'",
      # "    if ($content -match $pattern) {",
      # "        $content = $content -replace $pattern, ''",
      # "        Write-Output 'Removed RunSynchronous commands'",
      # "    }",
      "    # Save the modified content",
      "    $content | Set-Content -Path $xmlPath -Encoding UTF8",
      "    Write-Output 'Successfully modified unattend.xml'",
      "    Write-Output '--- Modified unattend.xml content ---'",
      "    Get-Content $xmlPath | Write-Output",
      "} else {",
      "    Write-Error 'unattend.xml not found at expected location'",
      "}"
    ]
  }

  provisioner "powershell" {
    valid_exit_codes = [0, 2]
    inline = [
      "Write-Output 'Removing temp directory.'",
      "Remove-Item -Recurse -Force ${var.temp_dir}",
      "Write-Output 'Disabling Windows Recovery Environment before Sysprep.'",
      "reagentc /disable",
      # "if( Test-Path $env:SystemRoot\\System32\\Sysprep\\unattend.xml ){ rm $env:SystemRoot\\System32\\Sysprep\\unattend.xml -Force}",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /mode:vm /quiet /quit /unattend:\"C:\\ProgramData\\Amazon\\EC2Launch\\sysprep\\unattend.xml\"",
      "$timeout = New-TimeSpan -Minutes 15",
      "$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()",
      "$successState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'",
      "$failureState = 'IMAGE_STATE_UNDEPLOYABLE'",
      "while($stopwatch.Elapsed -lt $timeout) {",
      "    $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select-Object -ExpandProperty ImageState -ErrorAction SilentlyContinue",
      "    if($imageState -eq $successState) {",
      "        Write-Output 'Sysprep completed successfully.'",
      "        break",
      "    }",
      "    if($imageState -eq $failureState) {",
      "        Write-Error 'Sysprep failed. State is UNDEPLOYABLE.'",
      "        $pantherPath = \"$env:SystemRoot\\System32\\Sysprep\\Panther\"",
      "        if (Test-Path $pantherPath) {",
      "            Get-ChildItem -Path $pantherPath -Filter '*.log' -Recurse | ForEach-Object {",
      "                Write-Output \"--- Log file: $_.FullName ---\"",
      "                Get-Content $_.FullName | Write-Output",
      "            }",
      "        }",
      "        exit 1",
      "    }",
      "    Write-Output \"Current ImageState: $imageState. Waiting...\"",
      "    Start-Sleep -s 10",
      "}",
      "if ($stopwatch.Elapsed -ge $timeout) {",
      "    Write-Error \"Sysprep did not complete in time. Last state: $imageState\"",
      "    $pantherPath = \"$env:SystemRoot\\System32\\Sysprep\\Panther\"",
      "    if (Test-Path $pantherPath) {",
      "        Get-ChildItem -Path $pantherPath -Filter '*.log' -Recurse | ForEach-Object {",
      "            Write-Output \"--- Log file (timeout): $_.FullName ---\"",
      "            Get-Content $_.FullName | Write-Output",
      "        }",
      "    }",
      "    exit 1",
      "}"
    ]
  }

}
