require "minitest/autorun"
require "tmpdir"
require "open3"
require "json"

class InstallRunnerPackageTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/build/install-runner-package.sh", __dir__)

  # Stands in for upstream's helpers/install.sh, and for the commands that
  # would write to /opt.
  HELPERS = <<~'SH'
    get_github_api_json() {
      case "$1" in
        repos/actions/runner/releases/latest) echo '{"tag_name": "v2.338.0"}' ;;
        "repos/runs-on/runner/releases?per_page=100") cat "$FORK_RELEASES" ;;
        *) return 1 ;;
      esac
    }
    download_with_retry() { echo "download $1" >>"$LOG"; echo "/tmp/${1##*/}"; }
    get_checksum_from_url() { echo "checksum $1 $2" >>"$LOG"; echo "c0ffee"; }
    use_checksum_comparison() { echo "verify $1 $2" >>"$LOG"; }
    mkdir() { :; }
    mv() { echo "install $2" >>"$LOG"; }
  SH

  def run_script(fork_tags)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/install.sh", HELPERS)
      File.write("#{dir}/releases.json", fork_tags.map { |tag| { tag_name: tag } }.to_json)
      env = { "HELPER_SCRIPTS" => dir, "FORK_RELEASES" => "#{dir}/releases.json", "LOG" => "#{dir}/log" }
      output, status = Open3.capture2e(env, "bash", SCRIPT)
      log = File.exist?("#{dir}/log") ? File.read("#{dir}/log") : ""
      [status, output, log]
    end
  end

  def test_installs_the_newest_fork_revision_of_the_latest_upstream_release
    status, output, log = run_script(%w[v2.338.0-runs-on.9 v2.338.0-runs-on.10 v2.337.0-runs-on.12])

    assert status.success?, output
    release = "https://github.com/runs-on/runner/releases/download/v2.338.0-runs-on.10"
    assert_equal <<~LOG, log
      download #{release}/actions-runner-linux-x64-2.338.0.tar.gz
      checksum #{release}/SHA256SUMS actions-runner-linux-x64-2.338.0.tar.gz
      verify /tmp/actions-runner-linux-x64-2.338.0.tar.gz c0ffee
      install /opt/runner-cache/actions-runner-linux-x64-2.338.0.tar.gz
    LOG
  end

  def test_fails_until_the_fork_publishes_the_latest_upstream_release
    status, output, log = run_script(%w[v2.337.0-runs-on.1])

    refute status.success?
    assert_includes output, "runs-on/runner has not published actions/runner v2.338.0 yet"
    assert_empty log
  end
end
