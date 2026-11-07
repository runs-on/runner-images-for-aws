require "minitest/autorun"
require "tmpdir"
require "open3"
require "fileutils"

class PruneVulnerableLeftoversTest < Minitest::Test
  SCRIPT = File.expand_path("../patches/ubuntu/files/prune-vulnerable-leftovers.sh", __dir__)

  def run_script(dist_infos)
    Dir.mktmpdir do |root|
      dist_infos.each { |path| FileUtils.mkdir_p(File.join(root, path)) }
      output, status = Open3.capture2e("bash", SCRIPT, root)
      assert status.success?, output
      remaining = Dir.glob(File.join(root, "**/*.dist-info")).map { |path| path.delete_prefix("#{root}/") }.sort
      yield remaining
    end
  end

  def test_keeps_only_newest_dist_info_per_package
    pypy = "opt/hostedtoolcache/PyPy/3.11.17/x64/lib/pypy3.11/site-packages"
    python = "opt/hostedtoolcache/Python/3.15.2/x64/lib/python3.15/site-packages"
    conda = "usr/share/miniconda/lib/python3.14/site-packages"
    other = "opt/az/lib/python3.14/site-packages"

    run_script([
      "#{pypy}/pip-24.0.dist-info",
      "#{pypy}/pip-26.2.2.dist-info",
      "#{pypy}/pip_tools-7.4.1.dist-info",
      "#{pypy}/setuptools-80.9.0.dist-info",
      "#{python}/pip-26.2.2.dist-info",
      "#{python}/pip-26.10.0.dist-info",
      "#{conda}/brotlicffi-1.2.0.1.dist-info",
      "#{conda}/brotlicffi-1.2.1.0.dist-info",
      "#{other}/pip-26.2.1.dist-info",
      "#{other}/pip-26.3.dist-info",
    ]) do |remaining|
      assert_equal [
        "#{other}/pip-26.2.1.dist-info",
        "#{other}/pip-26.3.dist-info",
        "#{pypy}/pip-26.2.2.dist-info",
        "#{pypy}/pip_tools-7.4.1.dist-info",
        "#{pypy}/setuptools-80.9.0.dist-info",
        "#{python}/pip-26.10.0.dist-info",
        "#{conda}/brotlicffi-1.2.1.0.dist-info",
      ].sort, remaining
    end
  end
end
