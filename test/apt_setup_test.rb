require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"

class AptSetupTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_patch_runs_apt_setup_without_a_mirror_file_or_prompts
    %w[ubuntu22 ubuntu24 ubuntu26].product(%w[x64 arm64]).each do |dist, arch|
      Dir.mktmpdir do |dir|
        build = "#{dir}/images/ubuntu/scripts/build"
        FileUtils.mkdir_p(build)
        tests = "#{dir}/images/ubuntu/scripts/tests"
        FileUtils.mkdir_p(tests)
        File.write("#{tests}/Java.Tests.ps1", "")
        FileUtils.cp("#{__dir__}/fixtures/apt/System.Tests.ps1", tests)
        FileUtils.mkdir_p("#{dir}/images/ubuntu/toolsets")
        File.write("#{dir}/images/ubuntu/toolsets/toolset-2204.json", "{}")
        FileUtils.cp(Dir["#{__dir__}/fixtures/apt/*.sh"], build)
        %w[install-google-chrome install-aws-tools install-php install-java-tools].each do |name|
          File.write("#{build}/#{name}.sh", "")
        end
        output, status = Open3.capture2e("bash", "-c", <<~SH, chdir: ROOT)
          set -e
          DIST=#{dist} ARCH=#{arch} TOOLSET_FILE=toolset-2204.json
          source bin/patch/lib.sh
          yq() { :; }
          patch_ubuntu '#{dir}'
        SH
        assert status.success?, output
        assert_equal File.read("#{ROOT}/patches/ubuntu/tests/Apt.Tests.ps1"), File.read("#{tests}/Apt.Tests.ps1")
        environment = File.read("#{build}/configure-environment.sh")
        if dist == "ubuntu22"
          refute_includes environment, "rootflags="
          refute_includes environment, "99-runner-performance.cfg"
          system_tests = File.read("#{tests}/System.Tests.ps1")
          refute_includes system_tests, 'Describe "Root filesystem performance options"'
          assert_includes system_tests, 'Should -Contain "data=ordered"'
          assert_includes system_tests, 'Describe "Dpkg options"'
        else
          assert_includes environment, "rootflags=nobarrier,data=writeback,journal_async_commit,commit=30"
        end
        assert_includes environment, '# Create symlink for tests running'
        icu = File.read("#{build}/configure-dpkg.sh")
        assert_includes icu, "libicu70_70.1-2_#{arch == 'arm64' ? 'arm64' : 'amd64'}.deb"
        if arch == "arm64"
          assert_includes icu, "https://ports.ubuntu.com/ubuntu-ports/pool/main/i/icu/"
          assert_includes icu, "14ebf6ca091cdbda96aa15821eb02a72dc2156d5bcfa820e7cb9dad5e528f31452d9bdbd806c0cbd49b4d3a4d8dedc28ae52053727810e0ad74fd31bcf9b623c"
          refute_includes icu, "libicu70_70.1-2_amd64.deb"
        end
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
