require "minitest/autorun"
require "yaml"

class WindowsTemplateTest < Minitest::Test
  CONFIG = YAML.load_file(File.expand_path("../config.yml", __dir__))
  TEMPLATE_DIR = File.expand_path("../patches/windows/templates", __dir__)
  EC2LAUNCH_CONFIG_PATH = File.expand_path("../patches/windows/files/ec2launch-agent-config.yml", __dir__)
  BUILD_SCRIPT_PATH = File.expand_path("../bin/build", __dir__)
  STACK_SMOKE_PATH = File.expand_path("../bin/utils/windows-full-stack-smoke.ps1", __dir__)
  RUNS_ON_LAUNCH_INSTALLER_PATH = File.expand_path("../patches/windows/build/Install-RunsOnLaunch.ps1", __dir__)
  BOOT_DIAGNOSTICS_PATH = File.expand_path("../patches/windows/build/Configure-WindowsBootDiagnostics.ps1", __dir__)
  BOOT_DIAGNOSTICS_COLLECTOR_PATH = File.expand_path("../bin/utils/collect-windows-boot-diagnostics.ps1", __dir__)
  CORE_FEASIBILITY_PATH = File.expand_path("../patches/windows/build/Test-ServerCoreFeasibility.ps1", __dir__)

  def test_windows_images_use_400_mibps_gp3_throughput
    images = CONFIG.fetch("images").select { |image| image.fetch("id").start_with?("windows") }

    refute_empty images
    images.each do |image|
      assert_equal 400, image.fetch("volume_throughput"), image.fetch("id")

      template_name = image.fetch("template", image.fetch("id"))
      template = File.read(File.join(TEMPLATE_DIR, "#{template_name}.pkr.hcl"))
      assert_includes template, 'variable "volume_throughput"', image.fetch("id")
      assert_match(/throughput\s*=\s*var\.volume_throughput/, template, image.fetch("id"))
    end
  end

  def test_windows25_full_skips_redundant_root_extension
    template = File.read(File.join(TEMPLATE_DIR, "windows25-full-x64.pkr.hcl"))
    patch_script = File.read(File.expand_path("../bin/patch/windows25-x64", __dir__))
    agent_config = YAML.load_file(EC2LAUNCH_CONFIG_PATH)
    tasks = agent_config.fetch("config").flat_map { |stage| stage.fetch("tasks") }.map { |task| task.fetch("task") }

    refute_includes tasks, "extendRootPartition"
    assert_includes tasks, "activateWindows"
    assert_includes tasks, "setAdminAccount"
    refute_includes tasks, "setDnsSuffix"
    refute_includes tasks, "setWallpaper"
    refute_includes tasks, "startSsm"
    assert_includes template, "EC2Launch.exe\\\" validate"
    assert_includes template, "EC2Launch configuration validation failed"
    assert_includes template, 'variable "publish_publicly"'
    assert_includes template, "ami_groups                   = var.publish_publicly ? [\"all\"] : []"
    assert_includes template, "snapshot_groups = var.publish_publicly ? [\"all\"] : []"
    assert_includes patch_script, 'cp patches/windows/files/ec2launch-agent-config.yml "$files_dir/"'
    assert_includes patch_script, 'GOOS=windows GOARCH=amd64 go -C tools/runs-on-launch build -trimpath -ldflags="-s -w" -o "$files_dir/runs-on-launch.exe" .'
    assert_includes patch_script, 'zip -j -9 "$files_dir/runs-on-launch.zip" "$files_dir/runs-on-launch.exe"'
    assert_includes patch_script, 'grep -Fqx "$patch_marker" "$target_file"'
    assert_includes patch_script, '.postgresql.version = "17.10.1"'
  end

  def test_runs_on_launch_is_built_and_installed_as_an_automatic_local_system_service
    template = File.read(File.join(TEMPLATE_DIR, "windows25-full-x64.pkr.hcl"))
    installer = File.read(RUNS_ON_LAUNCH_INSTALLER_PATH)

    assert_includes template, "../files/runs-on-launch.zip"
    assert_includes template, "Install-RunsOnLaunch.ps1"
    assert_includes installer, "start= demand"
    assert_includes installer, "obj= LocalSystem"
    assert_includes installer, '$installDirectory = "C:\\runs-on"'
    assert_includes installer, "sc.exe failure"
    assert_includes installer, "sc.exe config AmazonSSMAgent start= demand"
    assert_includes template, "Set-Service -Name RunsOnLaunch -StartupType Automatic"
  end

  def test_windows25_full_preserves_specialization_evidence
    template = File.read(File.join(TEMPLATE_DIR, "windows25-full-x64.pkr.hcl"))
    diagnostics = File.read(BOOT_DIAGNOSTICS_PATH)
    collector = File.read(BOOT_DIAGNOSTICS_COLLECTOR_PATH)

    assert_includes template, 'variable "capture_wpr_boot_trace"'
    assert_includes template, "Configure-WindowsBootDiagnostics.ps1"
    assert_includes diagnostics, "Microsoft-Windows-Hyper-V-Hypervisor-Operational"
    assert_includes diagnostics, "Microsoft-Windows-Kernel-Boot/Operational"
    assert_includes diagnostics, "Microsoft-Windows-Kernel-PnP/Configuration"
    assert_includes diagnostics, "Microsoft-Windows-Diagnostics-Performance/Operational"
    assert_includes diagnostics, "/retention:false /maxsize:67108864"
    refute_includes diagnostics, "/retention:true"
    assert_includes diagnostics, "wpr.exe -boottrace -addboot GeneralProfile -filemode"
    assert_includes collector, 'event-summary.json'
    assert_includes collector, 'Service Control Manager|Sysprep|UserPnp'
    assert_includes template, 'variable "hypervisor_launch_type"'
    assert_includes template, "hypervisorlaunchtype=Off is diagnostic-only and cannot be published"
    assert_includes template, "'${var.publish_publicly}' -eq 'true'"
    refute_includes template, "-and ${var.publish_publicly})"
    build_script = File.read(BUILD_SCRIPT_PATH)
    assert_includes build_script, 'HYPERVISOR_LAUNCH_TYPE=Off requires AMI_PUBLIC=false'
    assert_includes build_script, '"hypervisor_launch_type=#{hypervisor_launch_type}"'
  end

  def test_server_core_is_a_separate_nonblocking_compatibility_experiment
    template = File.read(File.join(TEMPLATE_DIR, "windows25-full-x64.pkr.hcl"))
    smoke = File.read(CORE_FEASIBILITY_PATH)

    refute CONFIG.fetch("images").any? { |image| image.fetch("id") == "windows25-core-x64" }
    assert_includes template, 'variable "server_core_feasibility"'
    assert_includes template, "ServerCore.AppCompatibility~~~~0.0.1.0"
    assert_includes template, "Install-Chrome.ps1"
    assert_includes smoke, "Chrome headless"
    assert_includes smoke, "Chrome WebDriver"
    assert_includes smoke, "Playwright with installed Chrome"
    assert_includes smoke, "Windows container"
  end

  def test_windows25_full_relies_on_source_ami_updates
    template = File.read(File.join(TEMPLATE_DIR, "windows25-full-x64.pkr.hcl"))

    refute_match(/^\s*"\$\{path\.root\}\/\.\.\/scripts\/build\/Install-WindowsUpdates(?:AfterReboot)?\.ps1"/,
      template)
  end

  def test_build_can_preserve_a_failed_builder_for_recovery
    build_script = File.read(BUILD_SCRIPT_PATH)

    assert_includes build_script, 'ENV.fetch("PACKER_ON_ERROR", "cleanup")'
    assert_includes build_script, '"-on-error=#{packer_on_error}"'
  end

  def test_full_stack_smoke_matches_the_enabled_runs_on_stack
    smoke = File.read(STACK_SMOKE_PATH)

    assert_includes smoke, '$env:IMAGE_FOLDER = $imageFolder'
    assert_includes smoke, '$env:TEMP = "C:\Windows\Temp"'
    assert_includes smoke, '$env:TEMP_DIR = $env:TEMP'
    assert_includes smoke, 'C:\actions-runner\bin\Runner.Listener.exe'
    assert_includes smoke, 'C:\actions-runner\bin\Runner.Worker.exe'
    assert_includes smoke, 'C:\Program Files\Git\bin\bash.exe'
    refute_match(/File = "ChocoPackages"\s*}/, smoke)
    refute_includes smoke, 'File = "Java"'
    refute_includes smoke, 'File = "Toolset"'
    assert_includes smoke, 'File = "Databases"; Filter = "*PostgreSQL*"'
    assert_includes smoke, '@{ Name = "Python 3.14"'
    assert_includes smoke, '@{ Name = "Go 1.26"'
    assert_includes smoke, 'OptionalFeature:$featureName'
    assert_includes smoke, "EC2Launch.exe\" validate"
    assert_includes smoke, "RunsOnLaunch starts bootstrap before SSM"
    assert_includes smoke, 'Start-Process -FilePath "C:\Program Files\Google\Chrome\Application\chrome.exe"'
    assert_includes smoke, "-Wait -PassThru -RedirectStandardOutput"
    assert_includes smoke, "Chrome WebDriver creates a session"
    assert_includes smoke, "Hyper-V is immediately usable"
    assert_includes smoke, "Windows container starts"
  end

end
