require "minitest/autorun"

class RunnerFinalizeUnitsTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/runner-finalize-units.sh", __dir__)
  TEMPLATE_DIR = File.expand_path("../patches/ubuntu/templates", __dir__)

  def setup
    @content = File.read(SCRIPT)
  end

  def test_needrestart_is_configured_for_ci_jobs
    assert_includes @content, "/etc/needrestart/conf.d"
    assert_includes @content, "99-runs-on-ci.conf"
    assert_includes @content, "$nrconf{restart} = 'l';"
    assert_includes @content, "$nrconf{override_rc}->{qr(^runs-on-bootstrap\\.service$)} = 0;"
    assert_includes @content, "restart hooks must never restart that service"
  end

  def test_packagekit_units_are_masked
    assert_includes masked_units, "packagekit.service"
    assert_includes masked_units, "packagekit-offline-update.service"
    assert_includes masked_units, "packagekit-offline-update.timer"
  end

  def test_full_templates_apply_only_package_restart_guards
    %w[ubuntu-full-arm64.pkr.hcl ubuntu-full-x64.pkr.hcl].each do |template_name|
      template = File.read(File.join(TEMPLATE_DIR, template_name))

      assert_includes template, "runner-finalize-units.sh", template_name
      assert_includes template, "RUNNER_FINALIZE_UNITS_MODE=package-restarts-only", template_name
    end
  end

  def test_full_templates_can_build_private_dev_amis
    %w[ubuntu-full-arm64.pkr.hcl ubuntu-full-x64.pkr.hcl].each do |template_name|
      template = File.read(File.join(TEMPLATE_DIR, template_name))

      assert_includes template, 'variable "ami_public"', template_name
      assert_includes template, 'ami_groups    = var.ami_public ? ["all"] : []', template_name
      assert_includes template, 'snapshot_groups = var.ami_public ? ["all"] : []', template_name
    end
  end

  private

  def masked_units
    @content
      .scan(/^\s*mask_target_units\s+\\\n((?:\s+\S+(?:\s+\\)?\n)+)/)
      .flatten
      .join("\n")
      .scan(/[A-Za-z0-9@_.-]+\.(?:automount|service|socket|target|timer)/)
  end
end
