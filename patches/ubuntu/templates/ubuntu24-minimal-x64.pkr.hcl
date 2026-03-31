packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
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

variable "region" {
  type    = string
  default = "${env("AWS_DEFAULT_REGION")}"
}

variable "ami_regions" {
  type = list(string)
}

variable "image_os" {
  type    = string
  default = "${env("IMAGE_OS")}"
}

variable "image_version" {
  type    = string
  default = "${env("IMAGE_VERSION")}"
}

variable "source_ami_owner" {
  type    = string
  default = "099720109477"
}

variable "source_ami_name" {
  type    = string
  default = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "subnet_id" {
  type    = string
  default = "${env("SUBNET_ID")}"
}

variable "volume_size" {
  type    = number
  default = 4
}

variable "volume_throughput" {
  type    = number
  default = 750
}

variable "volume_type" {
  type    = string
  default = "gp3"
}

variable "instance_type" {
  type    = string
  default = "m8a.large"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

source "amazon-ebssurrogate" "build_ebs" {
  aws_polling {
    delay_seconds = 30
    max_attempts  = 300
  }

  temporary_security_group_source_public_ip = true
  ami_name                                  = var.ami_name
  ami_description                           = var.ami_description
  ami_virtualization_type                   = "hvm"
  ami_architecture                          = "x86_64"
  ena_support                               = true
  ebs_optimized                             = true
  instance_type                             = var.instance_type
  iam_instance_profile                      = "SSMInstanceProfile"
  region                                    = var.region
  ssh_username                              = "ubuntu"
  subnet_id                                 = var.subnet_id
  associate_public_ip_address               = true
  force_deregister                          = true
  force_delete_snapshot                     = true

  ami_regions = var.ami_regions

  launch_block_device_mappings {
    device_name           = "/dev/sdf"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    throughput            = var.volume_throughput
    delete_on_termination = true
    encrypted             = false
  }

  ami_root_device {
    source_device_name    = "/dev/sdf"
    device_name           = "/dev/sda1"
    volume_type           = var.volume_type
    volume_size           = var.volume_size
    delete_on_termination = true
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
  sources = ["source.amazon-ebssurrogate.build_ebs"]

  provisioner "file" {
    source      = "${path.root}/../custom/files/rolaunch"
    destination = "/tmp/rolaunch"
  }

  provisioner "file" {
    source      = "${path.root}/../custom/files/rootfs-compaction.sh"
    destination = "/tmp/rootfs-compaction.sh"
  }

  provisioner "file" {
    destination = "/tmp/waagent.conf"
    source      = "${path.root}/../custom/files/waagent.conf"
  }

  provisioner "file" {
    source      = "${path.root}/../custom/files/install-runs-on-bootstrap.sh"
    destination = "/tmp/install-runs-on-bootstrap.sh"
  }

  provisioner "shell" {
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]
  }

  provisioner "file" {
    destination = "${var.helper_script_folder}"
    source      = "${path.root}/../scripts/helpers"
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
    source      = "${path.root}/../toolsets/toolset-2404.json"
  }

  provisioner "file" {
    destination = "${var.image_folder}/minimal-install-target-tooling.sh"
    source      = "${path.root}/../custom/files/minimal-install-target-tooling.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/minimal-install-target-docker.sh"
    source      = "${path.root}/../custom/files/minimal-install-target-docker.sh"
  }

  provisioner "file" {
    destination = "${var.image_folder}/grow-rootfs.sh"
    source      = "${path.root}/../custom/files/grow-rootfs.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "TARGET_VOLUME_SIZE_GB=${var.volume_size}",
      "UBUNTU_RELEASE=noble",
      "UBUNTU_MIRROR=http://${var.region}.ec2.archive.ubuntu.com/ubuntu",
      "UBUNTU_SECURITY_MIRROR=http://security.ubuntu.com/ubuntu",
      "ROLAUNCH_SOURCE=/tmp/rolaunch",
      "GROW_ROOTFS_SCRIPT_SOURCE=${var.image_folder}/grow-rootfs.sh",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root",
      "MINIMAL_TARGET_STATE_FILE=/var/lib/runs-on/minimal-target/state.env",
      "BOOTSTRAP_APT_TIMEOUT_SECONDS=900",
      "DEBOOTSTRAP_TIMEOUT_SECONDS=1200",
      "CHROOT_APT_TIMEOUT_SECONDS=900"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/bootstrap-minimal-base.sh"
    timeout         = "30m"
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "IMAGE_FOLDER=${var.image_folder}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "HELPER_SCRIPTS=${var.helper_script_folder}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root",
      "TARGET_UBUNTU_MIRROR=http://${var.region}.ec2.archive.ubuntu.com/ubuntu/",
      "TARGET_UBUNTU_SECURITY_MIRROR=http://security.ubuntu.com/ubuntu/",
      "WAAGENT_CONFIG_SOURCE=/tmp/waagent.conf"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/stage-minimal-target.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "IMAGE_FOLDER=${var.image_folder}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "HELPER_SCRIPTS=${var.helper_script_folder}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "MINIMAL_INCLUDE_FULL_INSTALLERS=false",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "ro-run-script-in-target ${var.installer_script_folder}/configure-image-data.sh",
      "ro-run-script-in-target ${var.installer_script_folder}/configure-environment.sh",
      "ro-run-script-in-target ${var.installer_script_folder}/configure-apt-mock.sh",
      "ro-run-script-in-target ${var.installer_script_folder}/configure-apt-sources.sh",
      "ro-run-script-in-target ${var.installer_script_folder}/configure-apt.sh",
      "ro-run-script-in-target ${var.installer_script_folder}/configure-limits.sh"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_VERSION=${var.image_version}",
      "IMAGE_OS=${var.image_os}",
      "IMAGE_FOLDER=${var.image_folder}",
      "IMAGEDATA_FILE=${var.imagedata_file}",
      "HELPER_SCRIPTS=${var.helper_script_folder}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "MINIMAL_INCLUDE_FULL_INSTALLERS=false",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "ro-run-script-in-target ${var.installer_script_folder}/install-runner-package.sh",
      "ro-run-script-in-target ${var.image_folder}/minimal-install-target-tooling.sh",
      "ro-run-script-in-target ${var.image_folder}/minimal-install-target-docker.sh"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_FOLDER=${var.image_folder}",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/runner-finalize-common.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "RUNNER_FINALIZE_VARIANT=minimal",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.root}/../custom/files/runner-finalize-units.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "IMAGE_FOLDER=${var.image_folder}",
      "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}",
      "ROOTFS_COMPACTION_HELPER=/tmp/rootfs-compaction.sh",
      "MINIMAL_TARGET_STATE_FILE=/var/lib/runs-on/minimal-target/state.env",
      "DEBIAN_FRONTEND=noninteractive",
      "TARGET_ROOT_MOUNT=/mnt/minimal-root"
    ]
    execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.root}/../custom/files/runner-finalize-cleanup.sh",
      "${path.root}/../custom/files/finalize-minimal-rootfs.sh"
    ]
  }
}
