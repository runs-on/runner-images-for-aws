require "minitest/autorun"

class UbuntuTemplateTest < Minitest::Test
  TEMPLATE_DIR = File.expand_path("../patches/ubuntu/templates", __dir__)

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
end
