require "minitest/autorun"

class RunnerFinalizeUnitsTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/runner-finalize-units.sh", __dir__)

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

  private

  def masked_units
    @content
      .scan(/^\s*mask_target_units\s+\\\n((?:\s+\S+(?:\s+\\)?\n)+)/)
      .flatten
      .join("\n")
      .scan(/[A-Za-z0-9@_.-]+\.(?:automount|service|socket|target|timer)/)
  end
end
