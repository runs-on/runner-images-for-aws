require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class AptSetupTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_patch_runs_apt_setup_without_a_mirror_file_or_prompts
    Dir.mktmpdir do |dir|
      build = "#{dir}/images/ubuntu/scripts/build"
      FileUtils.mkdir_p(build)
      tests = "#{dir}/images/ubuntu/scripts/tests"
      FileUtils.mkdir_p(tests)
      FileUtils.cp(Dir["#{__dir__}/fixtures/apt/*.sh"], build)
      %w[install-google-chrome install-aws-tools install-php configure-environment].each do |name|
        File.write("#{build}/#{name}.sh", "")
      end
      output, status = Open3.capture2e("bash", "-c", <<~SH, chdir: ROOT)
        set -e
        DIST=ubuntu22 ARCH=x64 TOOLSET_FILE=toolset-2204.json
        source bin/patch/lib.sh
        yq() { :; }
        patch_ubuntu '#{dir}'
      SH
      assert status.success?, output
      assert_equal File.read("#{ROOT}/patches/ubuntu/tests/Apt.Tests.ps1"), File.read("#{tests}/Apt.Tests.ps1")
      apt = "#{dir}/apt"
      FileUtils.mkdir_p("#{apt}/apt.conf.d")
      File.write("#{apt}/sources.list", "deb https://archive.ubuntu.com/ubuntu jammy main\n")
      File.write("#{dir}/os.sh", <<~SH)
        is_ubuntu22() { return 0; }
        is_ubuntu22_arm64() { return 1; }
        is_ubuntu24_arm64() { return 1; }
        systemctl() { :; }
        curl() { :; }
        apt-get() { echo "APT $*"; }
      SH
      script = File.read("#{build}/configure-apt.sh").gsub("/etc/apt", apt)
      output, status = Open3.capture2e({"HELPER_SCRIPTS" => dir}, "bash", "-e", "-c", script)
      assert status.success?, output
      assert_includes output, "APT upgrade -y"
      assert_includes File.read("#{apt}/apt.conf.d/80-retries"), 'Acquire::Retries "5";'
      assert_includes File.read("#{apt}/apt.conf.d/80-retries"), 'Acquire::http::Timeout "20";'
      script = File.read("#{build}/install-ms-repos.sh")
      output, status = Open3.capture2e("bash", "-e", "-c", <<~SH + script)
        wget() { :; }; dpkg() { :; }; lsb_release() { echo 22.04; }
        apt-get() {
          case "$1" in
            install|dist-upgrade) [ "$2" = -y ] || return 100 ;;
          esac
        }
      SH
      assert status.success?, output
    end
  end

  def test_wrapper_preserves_success_failure_and_retry_exhaustion
    [[:success, 0, 1], [:failure, 100, 1], [:recover, 0, 2], [:exhaust, 100, 30]].each do |mode, expected, attempts|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p("#{dir}/wrappers")
        File.write("#{dir}/apt-get", <<~SH)
          #!/bin/sh
          count=$(cat '#{dir}/count' 2>/dev/null || echo 0)
          count=$((count + 1))
          echo "$count" > '#{dir}/count'
          case '#{mode}' in
            success) exit 0 ;;
            failure) echo 'package unavailable' >&2; exit 100 ;;
            recover) [ "$count" -gt 1 ] && exit 0 ;;
          esac
          echo 'Could not get lock' >&2
          exit 100
        SH
        FileUtils.chmod(0755, "#{dir}/apt-get")
        generator = File.read("#{ROOT}/patches/ubuntu/build/configure-apt-mock.sh")
          .sub("prefix=/usr/local/bin", "prefix=#{dir}/wrappers")
          .sub("/usr/bin/apt /usr/bin/apt-get /usr/bin/apt-key", "#{dir}/apt-get")
        output, status = Open3.capture2e("bash", "-e", "-c", generator)
        assert status.success?, output
        output, status = Open3.capture2e("sh", "-c", "sleep() { :; }; . '#{dir}/wrappers/apt-get'")
        assert_equal expected, status.exitstatus, "#{mode}: #{output}"
        assert_equal attempts, File.read("#{dir}/count").to_i
      end
    end
  end
end
