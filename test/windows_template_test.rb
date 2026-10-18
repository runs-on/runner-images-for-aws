require "minitest/autorun"

class WindowsTemplateTest < Minitest::Test
  TEMPLATE = File.expand_path("../patches/windows/templates/windows25-full-x64.pkr.hcl", __dir__)
  PATCH_SCRIPT = File.expand_path("../bin/patch/windows25-x64", __dir__)
  BOOT_SCRIPT = File.expand_path("../patches/windows/build/Configure-RunsOnBoot.ps1", __dir__)
  USER_PATCH = File.expand_path("../patches/windows/files/patch-Configure-User.ps1", __dir__)

  def test_boot_configuration_runs_last_and_is_copied_into_the_release
    scripts = File.read(TEMPLATE).scan(%r{scripts/build/([A-Za-z-]+\.ps1)}).flatten
    assert_operator scripts.index("Configure-RunsOnBoot.ps1"), :>, scripts.index("Configure-User.ps1")
    assert_includes File.read(PATCH_SCRIPT), "cp patches/windows/build/Configure-RunsOnBoot.ps1"
  end

  def test_native_images_are_kept_for_powershell
    patch = File.read(USER_PATCH)
    refute_match(/ngen\S* uninstall \*/, patch)
    assert_includes patch, "executeQueuedItems"
  end

  def test_ec2launch_config_leaves_only_dns_before_user_data
    config = File.read(BOOT_SCRIPT)[/\$agentConfig = @"\n(.*?)\n"@/m, 1]
    pre_ready = config[/stage: preReady\n(.*?)(?=  - stage:|\z)/m, 1]
    assert_includes pre_ready, "task: setDnsSuffix"
    refute_includes pre_ready, "activateWindows"
    refute_includes config, "extendRootPartition"
    refute_includes config, "setWallpaper"
    assert_includes File.read(BOOT_SCRIPT), 'Register-ScheduledTask -TaskName "RunsOn Windows activation"'
  end

  def test_boot_layout_is_traced_across_the_last_restart_and_packed
    template = File.read(TEMPLATE)
    trace = template.index("Start-BootTrace.ps1")
    restart = template.index('provisioner "windows-restart"', trace)
    optimize = template.index("Optimize-BootLayout.ps1")
    assert trace && restart && optimize, "trace, restart and optimize steps present"
    assert_operator trace, :<, restart
    assert_operator restart, :<, optimize
    patch = File.read(PATCH_SCRIPT)
    assert_includes patch, "GOOS=windows GOARCH=amd64 go build"
    assert_includes patch, "images/windows/assets/bootpack.exe"
  end
end
