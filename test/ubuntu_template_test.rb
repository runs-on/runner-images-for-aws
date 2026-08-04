require "minitest/autorun"
require "yaml"

class UbuntuTemplateTest < Minitest::Test
  BUILD_WORKFLOW = File.expand_path("../.github/workflows/build.yml", __dir__)
  BUILD_SCRIPT = File.expand_path("../bin/build", __dir__)
  CONFIG = YAML.load_file(File.expand_path("../config.yml", __dir__))
  TEMPLATE_DIR = File.expand_path("../patches/ubuntu/templates", __dir__)
  FULL_X64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-full-x64.pkr.hcl")
  FULL_ARM64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-full-arm64.pkr.hcl")
  GPU_X64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-gpu-x64.pkr.hcl")
  STEPSECURITY_X64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-stepsecurity-x64.pkr.hcl")
  STEPSECURITY_ARM64_TEMPLATE = File.join(TEMPLATE_DIR, "ubuntu-stepsecurity-arm64.pkr.hcl")
  DESCENDANT_TEMPLATES = [GPU_X64_TEMPLATE, STEPSECURITY_X64_TEMPLATE, STEPSECURITY_ARM64_TEMPLATE].freeze
  FULL_ROLAUNCH_SCRIPT = File.expand_path("../patches/ubuntu/files/configure-full-rolaunch.sh", __dir__)
  DESCENDANT_ROLAUNCH_SCRIPT = File.expand_path("../patches/ubuntu/files/finalize-rolaunch-descendant.sh", __dir__)
  GPU_INSTALL_SCRIPT = File.expand_path("../patches/ubuntu/build/install-gpu.sh", __dir__)
  MINIMAL_BASE_SCRIPT = File.expand_path("../patches/ubuntu/files/bootstrap-minimal-base.sh", __dir__)
  PATCH_LIB = File.expand_path("../bin/patch/lib.sh", __dir__)
  PRE_SCRIPT = File.expand_path("../patches/ubuntu/files/pre.sh", __dir__)
  TEST_WORKFLOW = File.expand_path("../.github/workflows/test.yml", __dir__)

  def test_configure_image_data_gets_helper_scripts_env
    offenders = Dir[File.join(TEMPLATE_DIR, "*.pkr.hcl")].filter_map do |template|
      content = File.read(template)
      blocks = content.scan(/provisioner "shell" \{.*?^\s*\}/m)
      bad_blocks = blocks.select do |block|
        block.include?("configure-image-data.sh") && !block.include?("HELPER_SCRIPTS=${var.helper_script_folder}")
      end

      File.basename(template) unless bad_blocks.empty?
    end

    assert_empty offenders
  end

  def test_templates_do_not_run_azure_apt_sources_rewrite
    # configure-apt-sources.sh is Azure-specific upstream behavior. In AWS
    # copied AMIs it freezes the build-region apt mirror into cloud-init's
    # runtime template instead of letting apt_configure choose the EC2 region.
    offenders = Dir[File.join(TEMPLATE_DIR, "*.pkr.hcl")].filter_map do |template|
      File.basename(template) if File.read(template).include?("configure-apt-sources.sh")
    end

    assert_empty offenders
  end

  def test_full_images_configure_official_cdn_apt_mirrors
    content = File.read(PRE_SCRIPT)

    assert_includes content, "https://archive.ubuntu.com/ubuntu/"
    assert_includes content, "https://security.ubuntu.com/ubuntu/"
    assert_includes content, "https://ports.ubuntu.com/ubuntu-ports/"
  end

  def test_minimal_images_use_architecture_appropriate_cdn_apt_mirrors
    x64 = File.read(File.join(TEMPLATE_DIR, "ubuntu24-minimal-x64.pkr.hcl"))
    arm64 = File.read(File.join(TEMPLATE_DIR, "ubuntu24-minimal-arm64.pkr.hcl"))

    assert_includes x64, "TARGET_UBUNTU_MIRROR=https://archive.ubuntu.com/ubuntu/"
    assert_includes x64, "TARGET_UBUNTU_SECURITY_MIRROR=https://security.ubuntu.com/ubuntu/"
    refute_match(/\.ec2\.(archive|ports)\.ubuntu\.com/, x64)

    assert_includes arm64, "TARGET_UBUNTU_MIRROR=https://ports.ubuntu.com/ubuntu-ports/"
    assert_includes arm64, "TARGET_UBUNTU_SECURITY_MIRROR=https://ports.ubuntu.com/ubuntu-ports/"
    refute_match(/\.ec2\.(archive|ports)\.ubuntu\.com/, arm64)
  end

  def test_only_ubuntu26_full_images_use_400_mibps_gp3_throughput
    configured = CONFIG.fetch("images").filter_map do |image|
      id = image.fetch("id")
      [id, image["volume_throughput"]] if id.match?(/\Aubuntu(?:22|24|26)-full-(?:x64|arm64)\z/)
    end.to_h

    assert_equal(
      {
        "ubuntu22-full-x64" => nil,
        "ubuntu22-full-arm64" => nil,
        "ubuntu24-full-x64" => nil,
        "ubuntu24-full-arm64" => nil,
        "ubuntu26-full-x64" => 400,
        "ubuntu26-full-arm64" => 400
      },
      configured
    )

    [FULL_X64_TEMPLATE, FULL_ARM64_TEMPLATE].each do |path|
      template = File.read(path)
      assert_includes template, 'variable "volume_throughput"', path
      assert_includes template, "throughput            = var.volume_throughput", path
    end
  end

  def test_only_ubuntu26_x64_full_and_descendants_select_compact_surrogate_builds
    compact_images = CONFIG.fetch("images").filter_map do |image|
      [image.fetch("id"), image.fetch("builder_volume_size")] if image.fetch("compact_root", false)
    end.to_h

    assert_equal(
      {
        "ubuntu26-full-x64" => 60,
        "ubuntu26-gpu-x64" => 80,
        "ubuntu26-stepsecurity-x64" => 60
      },
      compact_images
    )

    snapshot_limits = CONFIG.fetch("images").filter_map do |image|
      [image.fetch("id"), image.fetch("compact_snapshot_limit_gib")] if image.fetch("compact_root", false)
    end.to_h
    assert_equal(
      {
        "ubuntu26-full-x64" => 8,
        "ubuntu26-gpu-x64" => 12,
        "ubuntu26-stepsecurity-x64" => 8
      },
      snapshot_limits
    )

    build_script = File.read(BUILD_SCRIPT)
    assert_includes build_script, "image.fetch('compact_root', false)"
    assert_includes build_script, "compact_root is limited to Ubuntu 26 x64 images"
    assert_includes build_script, '"amazon-ebssurrogate.compact_root"'
    assert_includes build_script, '"amazon-ebs.build_ebs"'
    compact_images.each_key do |image_id|
      assert CONFIG.fetch("images").find { |image| image.fetch("id") == image_id }.fetch("compact_root")
    end
  end

  def test_compact_surrogates_snapshot_only_the_fresh_final_target
    [FULL_X64_TEMPLATE, GPU_X64_TEMPLATE, STEPSECURITY_X64_TEMPLATE].each do |path|
      template = File.read(path)
      surrogate = template[/source "amazon-ebssurrogate" "compact_root" \{.*?^\}/m]

      refute_nil surrogate, path
      assert_includes surrogate, "use_create_image", path
      assert_includes surrogate, "imds_support", path
      assert_match(%r{device_name\s*=\s*"/dev/sda1".*?omit_from_artifact\s*=\s*true}m, surrogate, path)
      assert_match(%r{device_name\s*=\s*"/dev/sdf".*?volume_size\s*=\s*var\.volume_size}m, surrogate, path)
      assert_match(%r{source_device_name\s*=\s*"/dev/sdf".*?device_name\s*=\s*"/dev/sda1"}m, surrogate, path)
      assert_equal 4, surrogate.scan("ami_name = var.ami_name").length, path
      refute_includes surrogate, "snapshot_id", path
      refute_includes surrogate, "uefi_data", path
      refute_includes surrogate, "boot_mode", path
    end

    [FULL_ARM64_TEMPLATE, STEPSECURITY_ARM64_TEMPLATE].each do |path|
      refute_includes File.read(path), 'amazon-ebssurrogate" "compact_root', path
    end
  end

  def test_ubuntu26_descendants_are_defined_for_supported_architectures
    configured = CONFIG.fetch("images").filter_map do |image|
      id = image.fetch("id")
      [id, image] if id.start_with?("ubuntu26-") && !id.include?("-full-")
    end.to_h

    assert_equal(
      %w[ubuntu26-gpu-x64 ubuntu26-stepsecurity-arm64 ubuntu26-stepsecurity-x64],
      configured.keys.sort
    )
    assert_equal "ubuntu-gpu-x64", configured.fetch("ubuntu26-gpu-x64").fetch("template")
    assert_equal "ubuntu-stepsecurity-x64", configured.fetch("ubuntu26-stepsecurity-x64").fetch("template")
    assert_equal "ubuntu-stepsecurity-arm64", configured.fetch("ubuntu26-stepsecurity-arm64").fetch("template")
    configured.each_value { |image| assert_equal 400, image.fetch("volume_throughput") }
  end

  def test_full_image_publication_can_be_disabled_without_changing_the_default
    build_script = File.read(BUILD_SCRIPT)

    [FULL_X64_TEMPLATE, FULL_ARM64_TEMPLATE, *DESCENDANT_TEMPLATES].each do |path|
      template = File.read(path)
      assert_includes template, 'variable "publish_publicly"', path
      assert_includes template, "default = true", path
      assert_match(/ami_groups\s*=\s*var\.publish_publicly \? \["all"\] : \[\]/, template, path)
      assert_match(/snapshot_groups\s*=\s*var\.publish_publicly \? \["all"\] : \[\]/, template, path)
    end
    assert_includes build_script, 'ENV.fetch("AMI_PUBLIC", "true")'
    assert_includes build_script, 'publish_publicly=#{publish_publicly}'
  end


  def test_ubuntu26_gpu_uses_available_cuda_and_kernel_matched_driver
    content = File.read(GPU_INSTALL_SCRIPT)

    assert_includes content, "if is_ubuntu26; then"
    assert_includes content, 'DIST_SLUG="ubuntu2604"'
    assert_includes content, 'linux-modules-nvidia-595-aws nvidia-driver-595'
    assert_includes content, 'CUDA_PACKAGES="cuda-toolkit-13-3"'
    assert_includes content, 'CUDA_MAJOR_VERSION="13"'
    assert_includes content, 'grep "release $CUDA_MAJOR_VERSION"'
    assert_includes content, '/usr/local/cuda-${CUDA_MAJOR_VERSION}/bin'
    assert_includes content, '/usr/local/cuda-${CUDA_MAJOR_VERSION}/lib64'
    assert_match(/if ! is_ubuntu26; then\s+cloud-init single --name cc_growpart\s+cloud-init single --name cc_resizefs/m, content)
    refute_includes content, "/usr/local/cuda-12/"
  end

  def test_ubuntu26_descendants_clear_inherited_launch_state
    finalizer = File.read(DESCENDANT_ROLAUNCH_SCRIPT)

    assert_match(/if \[\[ "\$\{IMAGE_OS:-\}" != "ubuntu26" \]\]; then.*?exit 0/m, finalizer)
    assert_includes finalizer, "systemctl start rolaunch.service"
    assert_includes finalizer, "/var/lib/rolaunch/runs-on-user-data.done"
    assert_includes finalizer, "/var/lib/rolaunch/instance-identity.json"
    assert_includes finalizer, "truncate -s 0 /etc/machine-id"
    assert_includes finalizer, "rm -f /var/lib/dbus/machine-id"
    assert_includes finalizer, "rm -f /etc/netplan/*.yaml"
    assert_includes finalizer, "/etc/systemd/network/10-runs-on-ec2.network"

    DESCENDANT_TEMPLATES.each do |path|
      template = File.read(path)
      assert_includes template, "IMAGE_OS=${var.image_os}", path
      assert_operator template.index("finalize-rolaunch-descendant.sh"), :>, template.index("after-reboot.sh"), path
      assert_includes template, 'variable "volume_throughput"', path
      assert_match(/throughput\s*=\s*var\.volume_throughput/, template, path)
    end
  end

  def test_full_rolaunch_is_staged_for_both_ubuntu26_architectures
    patch_lib = File.read(PATCH_LIB)

    assert_includes patch_lib, "ubuntu26-full-x64|ubuntu26-full-arm64)"
    assert_includes patch_lib, 'build_rolaunch "$build_dir/rolaunch"'
    [FULL_X64_TEMPLATE, FULL_ARM64_TEMPLATE].each do |path|
      template = File.read(path)
      assert_operator template.index("configure-full-rolaunch.sh"), :>, template.index("after-reboot.sh"), path
      assert_includes template, "ROLAUNCH_SOURCE=${var.installer_script_folder}/rolaunch", path
      refute_includes template, "${var.installer_script_folder}/build/rolaunch", path
    end
  end

  def test_full_rolaunch_activation_is_limited_to_ubuntu26
    patch_lib = File.read(PATCH_LIB)
    script = File.read(FULL_ROLAUNCH_SCRIPT)

    assert_match(/ubuntu26-full-x64\|ubuntu26-full-arm64\)\s+build_rolaunch/, patch_lib)
    refute_match(/ubuntu(?:22|24)-full-(?:x64|arm64)\)/, patch_lib)
    assert_match(/if \[\[ "\$\{IMAGE_OS\}" != "ubuntu26" \]\]; then.*?exit 0/m, script)
    assert_includes script, '"${VERSION_CODENAME:-}" != "resolute"'
  end

  def test_full_rolaunch_keeps_the_full_service_contract
    content = File.read(FULL_ROLAUNCH_SCRIPT)

    refute_includes content, "RUNNER_FINALIZE_VARIANT=minimal"
    refute_includes content, "enforce_allowlist"
    assert_includes content, "amazon-ssm-agent.service"
    assert_includes content, "chrony.service"
    assert_includes content, "irqbalance.service"
    assert_includes content, "https://archive.ubuntu.com/ubuntu/"
    assert_includes content, "https://security.ubuntu.com/ubuntu/"
    assert_includes content, "https://ports.ubuntu.com/ubuntu-ports/"
    assert_includes content, "Suites: resolute resolute-updates resolute-backports"
    assert_includes content, "Suites: resolute-security"
    refute_includes content, "noauto"
  end

  def test_full_rolaunch_uses_direct_networkd_and_disables_cloud_init
    content = File.read(FULL_ROLAUNCH_SCRIPT)

    assert_includes content, "/etc/systemd/network/10-runs-on-ec2.network"
    assert_includes content, "Driver=ena"
    assert_includes content, "DHCP=yes"
    assert_includes content, "IPv6AcceptRA=yes"
    assert_includes content, "UseDNS=yes"
    assert_includes content, "UseDomains=yes"
    assert_includes content, "UseHostname=no"
    assert_includes content, "/etc/cloud/cloud-init.disabled"
    assert_includes content, "cloud-init-local.service"
    assert_includes content, "cloud-init-main.service"
    assert_includes content, "cloud-init-network.service"
    assert_includes content, "cloud-init-hotplugd.socket"
    assert_includes content, "netplan-configure.service"
    assert_match(/systemctl mask .*cloud-init-main\.service/m, content)
    refute_match(/Wants=.*cloud-init/, content)
    assert_includes content, "ExecStart=/usr/bin/rolaunch --mode=full"
    refute_includes content, "Before=network-online.target"
    assert_includes content, "systemd-networkd-wait-online.service"
    assert_match(/systemctl mask .*systemd-networkd-wait-online\.service/m, content)
    assert_includes content, "systemd-resolved.service"
    assert_includes content, "../run/systemd/resolve/stub-resolv.conf"
    assert_includes content, "rm -f /etc/netplan/*.yaml"
    refute_includes content, "nameserver 169.254.169.253"
    refute_includes content, "apply_full_imds_network_config"
    assert_includes content, "truncate -s 0 /etc/machine-id"
    assert_includes content, "rm -f /var/lib/dbus/machine-id"
  end

  def test_ubuntu26_full_and_descendants_disable_new_boot_daemons
    [FULL_ROLAUNCH_SCRIPT, DESCENDANT_ROLAUNCH_SCRIPT].each do |path|
      content = File.read(path)

      assert_includes content, "systemctl disable netavark-dhcp-proxy.service udisks2.service", path
      assert_includes content, "systemctl enable netavark-dhcp-proxy.socket", path
      assert_includes content, "/usr/lib/systemd/system/sysinit.target.wants/systemd-binfmt.service", path
    end
  end

  def test_full_rolaunch_build_and_test_workflows_are_launcher_aware
    build_workflow = File.read(BUILD_WORKFLOW)
    test_workflow = File.read(TEST_WORKFLOW)

    assert_includes build_workflow, "inputs.image_id == 'ubuntu26-full-x64'"
    assert_includes build_workflow, "inputs.image_id == 'ubuntu26-full-arm64'"
    refute_includes build_workflow, "inputs.image_id == 'ubuntu24-full-x64'"
    assert_includes test_workflow, "journalctl --unit rolaunch.service"
    assert_includes test_workflow, "/var/lib/rolaunch/timings.json"
    assert_includes test_workflow, "/var/log/cloud-init-output.log"
  end

  def test_only_full_rolaunch_removes_the_systemd_start_deadline
    assert_includes File.read(FULL_ROLAUNCH_SCRIPT), "TimeoutStartSec=infinity"
    refute_includes File.read(MINIMAL_BASE_SCRIPT), "TimeoutStartSec=infinity"
  end
end
