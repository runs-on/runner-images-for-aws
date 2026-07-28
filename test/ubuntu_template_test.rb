require "minitest/autorun"

class UbuntuTemplateTest < Minitest::Test
  TEMPLATE_DIR = File.expand_path("../patches/ubuntu/templates", __dir__)
  PRE_SCRIPT = File.expand_path("../patches/ubuntu/files/pre.sh", __dir__)

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
end
