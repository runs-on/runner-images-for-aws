// Shared template for ubuntu{22,24,26}-full-x64. Version-specific bits are
// injected by bin/build: toolset_file (derived from the image id) and the full
// ordered install_scripts list from config.yml.
packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "= 1.8.0"
    }
  }
}

variable "ami_name" {
  type    = string
  default = "${env("AMI_NAME")}"
}

variable "ami_description" {
  type    = string
  default = "${env("AMI_DESCRIPTION")}"
}

variable "helper_script_folder" {
  type    = string
  default = "/imagegeneration/helpers"
}

variable "imagedata_file" {
  type    = string
  default = "/imagegeneration/imagedata.json"
}

variable "image_folder" {
  type    = string
  default = "/imagegeneration"
}

variable "image_os" {
  type = string
  // ex: ubuntu22
  default = "${env("IMAGE_OS")}"
}

variable "image_version" {
  type    = string
  default = "${env("IMAGE_VERSION")}"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "ami_regions" {
  type = list(string)
}

variable "publish_publicly" {
  type    = bool
  default = true
}

variable "source_ami_owner" {
  type = string
}

variable "source_ami_name" {
  type = string
}

// ex: toolset-2404.json
variable "toolset_file" {
  type = string
}

// Full ordered build script list (basenames) from config.yml.
variable "install_scripts" {
  type    = list(string)
  default = []
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

variable "builder_volume_size" {
  type    = number
  default = 60
}

variable "volume_throughput" {
  type    = number
  default = 125
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "m8a.large"
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
  # Make AMIs public for release builds; dev accounts can keep them private.
  ami_groups    = var.publish_publicly ? ["all"] : []
  ebs_optimized = true
  # spot_instance_types                       = ["r7a.large", "r7i.large", "m7a.xlarge", "c7a.xlarge", "m7i-flex.xlarge"]
  # spot_price                                = "1.00"
  instance_type               = var.instance_type
  region                      = "${var.region}"
  ssh_username                = "ubuntu"
  subnet_id                   = "${var.subnet_id}"
  associate_public_ip_address = "true"
  force_deregister            = "true"
  force_delete_snapshot       = "true"

  ami_regions = "${var.ami_regions}"

  // Keep the snapshot visibility aligned with the AMI.
  snapshot_groups = var.publish_publicly ? ["all"] : []

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "${var.volume_type}"
    volume_size           = "${var.volume_size}"
    throughput            = var.volume_throughput
    delete_on_termination = "true"
    encrypted             = "false"
  }

  run_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = "${var.ami_name}"
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
      name                = "${var.source_ami_name}"
      root-device-type    = "ebs"
    }
    owners      = ["${var.source_ami_owner}"]
    most_recent = true
  }
}

// Ubuntu 26 x64 builds on a disposable, enlarged source root and publishes
// only a fresh compact target. bin/build selects this source exclusively for
// ubuntu26-full-x64; Ubuntu 22 and 24 retain amazon-ebs.build_ebs unchanged.
source "amazon-ebssurrogate" "compact_root" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_architecture                          = "x86_64"
  ami_groups                                = var.publish_publicly ? ["all"] : []
  snapshot_groups                           = var.publish_publicly ? ["all"] : []
  ena_support                               = true
  ebs_optimized                             = true
  imds_support                              = "v2.0"
  use_create_image                          = true
  instance_type                             = var.instance_type
  region                                    = var.region
  ssh_username                              = "ubuntu"
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = true
  force_deregister                          = true
  force_delete_snapshot                     = true
  ami_regions                               = var.ami_regions

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.builder_volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
    omit_from_artifact    = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
  }

  ami_root_device {
    source_device_name    = "/dev/sdf"
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    iops                  = 3000
    throughput            = var.volume_throughput
    delete_on_termination = true
  }

  run_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  run_volume_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
  }

  snapshot_tags = {
    creator  = "RunsOn"
    contact  = "ops@runs-on.com"
    ami_name = var.ami_name
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

  sources = [
    "source.amazon-ebs.build_ebs",
    "source.amazon-ebssurrogate.compact_root"
  ]

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts         = ["${path.root}/../custom/files/pre.sh"]
  }

  # Dummy file added to please Azure script compatibility
  provisioner "file" {
    destination = "/tmp/waagent.conf"
    source      = "${path.root}/../custom/files/waagent.conf"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mv /tmp/waagent.conf /etc"]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]
  }

  provisioner "file" {
    destination = "${var.helper_script_folder}"
    source      = "${path.root}/../scripts/helpers"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../scripts/build/configure-apt-mock.sh"
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.root}/../scripts/build/install-ms-repos.sh",
      "${path.root}/../scripts/build/configure-apt.sh"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../scripts/build/configure-limits.sh"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}"
    source      = "${path.root}/../scripts/build"
  }

  provisioner "file" {
    destination = "${var.image_folder}"
    sources = [
      "${path.root}/../assets/post-gen",
      "${path.root}/../scripts/tests",
      "${path.root}/../scripts/docs-gen"
    ]
  }

  provisioner "file" {
    destination = "${var.image_folder}/docs-gen/"
    source      = "${path.root}/../../../helpers/software-report-base"
  }

  provisioner "file" {
    destination = "${var.installer_script_folder}/toolset.json"
    source      = "${path.root}/../toolsets/${var.toolset_file}"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mv ${var.image_folder}/docs-gen ${var.image_folder}/SoftwareReport",
      "mv ${var.image_folder}/post-gen ${var.image_folder}/post-generation"
    ]
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGEDATA_FILE=${var.imagedata_file}", "HELPER_SCRIPTS=${var.helper_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-image-data.sh"]
  }

  provisioner "shell" {
    environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "HELPER_SCRIPTS=${var.helper_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-environment.sh"]
  }

  provisioner "shell" {
    environment_vars = ["DEBIAN_FRONTEND=noninteractive", "HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-apt-vital.sh"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-powershell.sh"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'"
    // scripts          = ["${path.root}/../scripts/build/Install-PowerShellModules.ps1", "${path.root}/../scripts/build/Install-PowerShellAzModules.ps1"]
    scripts = ["${path.root}/../scripts/build/Install-PowerShellModules.ps1"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = [for s in var.install_scripts : "${path.root}/../scripts/build/${s}"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "DOCKERHUB_PULL_IMAGES=NO"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/install-docker.sh"]
  }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} pwsh -f {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/Install-Toolset.ps1", "${path.root}/../scripts/build/Configure-Toolset.ps1"]
  }

  // provisioner "shell" {
  //   environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  //   scripts          = ["${path.root}/../scripts/build/install-pipx-packages.sh"]
  // }

  // provisioner "shell" {
  //   environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   execute_command  = "/bin/sh -c '{{ .Vars }} {{ .Path }}'"
  //   scripts          = ["${path.root}/../scripts/build/install-homebrew.sh"]
  // }

  provisioner "shell" {
    environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}"]
    execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts          = ["${path.root}/../scripts/build/configure-snap.sh"]
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts         = ["${path.root}/../custom/files/runner-user.sh"]
  }

  provisioner "shell" {
    execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    inline            = ["echo 'Reboot VM'", "sudo reboot"]
  }

  provisioner "shell" {
    execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    pause_before        = "1m0s"
    scripts             = ["${path.root}/../scripts/build/cleanup.sh"]
    start_retry_timeout = "10m"
  }

  // provisioner "shell" {
  //   environment_vars = ["IMAGE_VERSION=${var.image_version}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}"]
  //   inline           = ["pwsh -File ${var.image_folder}/SoftwareReport/Generate-SoftwareReport.ps1 -OutputDirectory ${var.image_folder}", "pwsh -File ${var.image_folder}/tests/RunAll-Tests.ps1 -OutputDirectory ${var.image_folder}"]
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../Ubuntu2404-Readme.md"
  //   direction   = "download"
  //   source      = "${var.image_folder}/software-report.md"
  // }

  // provisioner "file" {
  //   destination = "${path.root}/../software-report.json"
  //   direction   = "download"
  //   source      = "${var.image_folder}/software-report.json"
  // }

  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPT_FOLDER=${var.helper_script_folder}",
      "IMAGE_FOLDER=${var.image_folder}",
      "IMAGE_OS=${var.image_os}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "ROLAUNCH_SOURCE=${var.installer_script_folder}/rolaunch"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.root}/../scripts/build/configure-system.sh",
      "${path.root}/../custom/files/after-reboot.sh",
      "${path.root}/../custom/files/configure-full-rolaunch.sh",
      "${path.root}/../custom/files/prepare-direct-uefi.sh"
    ]
  }

  provisioner "shell" {
    only            = ["amazon-ebssurrogate.compact_root"]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["install -d -o ubuntu -g ubuntu -m 0755 /run/runs-on-compact-root"]
  }

  provisioner "file" {
    only        = ["amazon-ebssurrogate.compact_root"]
    destination = "/run/runs-on-compact-root/"
    sources = [
      "${path.root}/../custom/files/compact-root-acl.py",
      "${path.root}/../custom/files/compact-root-direct-init",
      "${path.root}/../custom/files/compact-root-recovery-init",
      "${path.root}/../custom/files/compact-root-tree-manifest.py",
      "${path.root}/../custom/files/compact-root.boot-profile",
      "${path.root}/../custom/files/filter-compact-root-boot-profile.py",
      "${path.root}/../custom/files/prepare-direct-uefi.sh"
    ]
  }

  provisioner "shell" {
    only = ["amazon-ebssurrogate.compact_root"]
    environment_vars = [
      "COMPACT_ROOT_ASSET_DIR=/run/runs-on-compact-root",
      "COMPACT_ROOT_VARIANT=full",
      "IMAGE_OS=${var.image_os}",
      "TARGET_VOLUME_SIZE_GB=${var.volume_size}"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/finalize-compact-root.sh"
  }

  // provisioner "shell" {
  //   execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline          = ["sleep 30", "/usr/sbin/waagent -force -deprovision+user && export HISTSIZE=0 && sync"]
  // }

}
