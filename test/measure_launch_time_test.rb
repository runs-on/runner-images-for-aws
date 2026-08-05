require "minitest/autorun"
require "aws-sdk-ec2"
require "bigdecimal"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "time"
require "timeout"

class MeasureLaunchTimeTest < Minitest::Test
  HELPER_PATH = File.expand_path("../bin/utils/measure-launch-time", __dir__)
  PROFILE_HELPER_PATH = File.expand_path("../bin/utils/profile-boot", __dir__)
  HELPER_METHODS = Module.new.tap do |mod|
    source = File.read(HELPER_PATH)
    methods = source[/^def linux_user_data.*?(?=^ec2 =)/m]
    raise "unable to locate measure-launch-time methods" unless methods

    mod.module_eval(methods, HELPER_PATH, source[0, source.index(methods)].count("\n") + 1)
  end

  class Harness
    include HELPER_METHODS
  end

  Status = Struct.new(:successful, :exitstatus) do
    def success?
      successful
    end
  end

  EbsMapping = Struct.new(:volume_size, :volume_type, :iops, :throughput, keyword_init: true)
  BlockMapping = Struct.new(:device_name, :ebs, keyword_init: true)
  Image = Struct.new(:image_id, :root_device_name, :block_device_mappings, keyword_init: true)

  class FakeTerminationClient
    attr_reader :termination_requests, :wait_requests

    def initialize(fail_termination_for: nil, fail_wait: false)
      @termination_requests = []
      @wait_requests = []
      @fail_termination_for = fail_termination_for
      @fail_wait = fail_wait
    end

    def terminate_instances(instance_ids:)
      @termination_requests << instance_ids
      raise "termination failed" if instance_ids.include?(@fail_termination_for)
    end

    def wait_until(waiter, instance_ids:)
      @wait_requests << [waiter, instance_ids]
      raise "wait failed" if @fail_wait
    end
  end

  def setup
    @harness = Harness.new
  end

  def test_read_rolaunch_ready_seconds_uses_pending_time_as_origin
    capture = lambda do |*command, timeout_seconds:|
      @captured_command = command
      refute_nil timeout_seconds
      [rolaunch_output(done_at: "2026-08-03T01:02:13.250Z"), "", Status.new(true, 0)]
    end

    elapsed = @harness.stub(:capture3_with_timeout, capture) do
      @harness.read_rolaunch_ready_seconds(
        ip: "203.0.113.10",
        ssh_user: "ubuntu",
        private_key_path: "/tmp/key",
        timeout_seconds: 0
      )
    end

    assert_in_delta 10.25, elapsed, 0.001
    assert_equal "ssh", @captured_command.first
    assert_includes @captured_command, "ubuntu@203.0.113.10"
    assert_includes @captured_command.last, "/var/lib/rolaunch/instance-identity.json"
    assert_includes @captured_command.last, "/var/lib/rolaunch/timings.json"
  end

  def test_common_ready_seconds_uses_guest_marker_and_ec2_launch_time
    capture = lambda do |*command, timeout_seconds:|
      @captured_command = command
      refute_nil timeout_seconds
      ["2026-08-03T01:02:13.250000000Z\n", "", Status.new(true, 0)]
    end

    elapsed = @harness.stub(:capture3_with_timeout, capture) do
      @harness.read_common_ready_seconds(
        ip: "203.0.113.10",
        ssh_user: "ubuntu",
        private_key_path: "/tmp/key",
        launch_time: Time.iso8601("2026-08-03T01:02:03Z"),
        timeout_seconds: 1
      )
    end

    assert_in_delta 10.25, elapsed, 0.001
    assert_includes @captured_command.last, "/run/runs-on-boot-benchmark-ready"
    refute_includes @captured_command.last, "169.254.169.254"
  end

  def test_wait_for_public_ip_returns_ec2_launch_time
    launch_time = Time.iso8601("2026-08-03T01:02:03Z")
    instance = Struct.new(:public_ip_address, :launch_time).new("203.0.113.10", launch_time)
    reservation = Struct.new(:instances).new([instance])
    response = Struct.new(:reservations).new([reservation])
    ec2 = Object.new
    ec2.define_singleton_method(:describe_instances) { |instance_ids:| response }

    ip, actual_launch_time = @harness.wait_for_public_ip(ec2, "i-test", timeout_seconds: 0)

    assert_equal "203.0.113.10", ip
    assert_same launch_time, actual_launch_time
  end

  def test_wait_for_ssh_enforces_a_hard_deadline_for_stalled_sessions
    capture = lambda do |*_command, timeout_seconds:|
      sleep timeout_seconds
      raise Timeout::Error, "stalled SSH"
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    @harness.stub(:capture3_with_timeout, capture) do
      assert_raises(RuntimeError) do
        @harness.wait_for_ssh(
          ip: "203.0.113.10",
          ssh_user: "ubuntu",
          private_key_path: "/tmp/key",
          timeout_seconds: 0.1
        )
      end
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.5
  end

  def test_wait_for_new_boot_id_ignores_original_boot_and_disconnects
    old_boot = "11111111-1111-1111-1111-111111111111"
    new_boot = "22222222-2222-2222-2222-222222222222"
    responses = [
      ["#{old_boot}\n", "", Status.new(true, 0)],
      ["", "connection refused", Status.new(false, 255)],
      ["#{new_boot}\n", "", Status.new(true, 0)]
    ]
    capture = lambda do |**_arguments|
      responses.shift
    end

    actual = @harness.stub(:ssh_capture, capture) do
      @harness.wait_for_new_boot_id(
        ip: "203.0.113.10",
        ssh_user: "ubuntu",
        private_key_path: "/tmp/key",
        previous_boot_id: old_boot,
        timeout_seconds: 1,
        poll_interval: 0
      )
    end

    assert_equal new_boot, actual
    assert_empty responses
  end

  def test_compact_recovery_verification_checks_reboot_firmware_and_root_growth
    old_boot = "11111111-1111-1111-1111-111111111111"
    new_boot = "22222222-2222-2222-2222-222222222222"
    remote_commands = []
    capture = lambda do |**arguments|
      remote_commands << arguments.fetch(:remote_command)
      if remote_commands.length == 1
        ["#{old_boot}\n", "", Status.new(true, 0)]
      else
        ["recovery_boot_id=#{new_boot}\nboot_path=grub-initramfs-recovery\n", "", Status.new(true, 0)]
      end
    end
    wait = lambda do |**arguments|
      assert_equal old_boot, arguments.fetch(:previous_boot_id)
      new_boot
    end

    evidence = @harness.stub(:ssh_capture, capture) do
      @harness.stub(:wait_for_new_boot_id, wait) do
        @harness.verify_compact_recovery!(
          ip: "203.0.113.10",
          ssh_user: "ubuntu",
          private_key_path: "/tmp/key",
          timeout_seconds: 30,
          expected_root_gib: 60,
          nonce: "fixed-nonce"
        )
      end
    end

    assert_includes evidence, "grub-initramfs-recovery"
    assert_includes remote_commands.first, "systemd-run"
    assert_includes remote_commands.first, "fixed-nonce"
    validation = remote_commands.last
    assert_includes validation, "expected-recovery-cmdline"
    assert_includes validation, "expected-boot-order"
    assert_includes validation, "check_equal 'recovery kernel command line'"
    assert_includes validation, "check_equal 'recovery BootCurrent'"
    assert_includes validation, "check_empty 'recovery BootNext'"
    assert_includes validation, "observe_equal 'recovery BootOrder'"
    assert_includes validation, "expected_disk_bytes=$((60 * 1024 * 1024 * 1024))"
    assert_includes validation, "check_ge 'root partition uses the expanded disk'"
    assert_includes validation, "filesystem_bytes"
    remote_commands.each do |remote_command|
      _stdout, syntax_stderr, syntax_status = Open3.capture3("bash", "-n", stdin_data: remote_command)
      assert syntax_status.success?, syntax_stderr
    end
  end

  def test_compact_recovery_failure_reports_passes_and_expected_actual_failure
    old_boot = "11111111-1111-1111-1111-111111111111"
    new_boot = "22222222-2222-2222-2222-222222222222"
    calls = 0
    capture = lambda do |**_arguments|
      calls += 1
      if calls == 1
        ["PASS initial boot path: direct-uefi\n#{old_boot}\n", "", Status.new(true, 0)]
      else
        [
          "PASS recovery root filesystem type: overlay\n",
          "FAIL root disk size\n  expected: 64424509440\n  actual:   32212254720\n",
          Status.new(false, 1)
        ]
      end
    end

    error = @harness.stub(:ssh_capture, capture) do
      @harness.stub(:wait_for_new_boot_id, new_boot) do
        assert_raises(RuntimeError) do
          @harness.verify_compact_recovery!(
            ip: "203.0.113.10",
            ssh_user: "ubuntu",
            private_key_path: "/tmp/key",
            timeout_seconds: 30,
            nonce: "fixed-nonce"
          )
        end
      end
    end

    assert_includes error.message, "Compact recovery validation failed"
    assert_includes error.message, "PASS recovery root filesystem type: overlay"
    assert_includes error.message, "FAIL root disk size"
    assert_includes error.message, "expected: 64424509440"
    assert_includes error.message, "actual:   32212254720"
  end

  def test_cli_rejects_negative_warm_run_count
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      HELPER_PATH,
      "ami-test",
      "--warm-runs=-1"
    )

    refute status.success?
    assert_includes stderr, "--warm-runs must be zero or greater"
  end

  def test_cli_rejects_zero_measured_runs
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      HELPER_PATH,
      "ami-test",
      "--measure-runs=0"
    )

    refute status.success?
    assert_includes stderr, "--measure-runs must be greater than zero"
  end

  def test_read_rolaunch_ready_seconds_retries_until_done_timing_exists
    attempts = 0
    capture = lambda do |*_command, timeout_seconds:|
      refute_nil timeout_seconds
      attempts += 1
      stdout = if attempts == 1
                 rolaunch_output(steps: [{ "Name" => "rolaunch.started", "Time" => "2026-08-03T01:02:04Z" }])
               else
                 rolaunch_output(done_at: "2026-08-03T01:02:05Z")
               end
      [stdout, "", Status.new(true, 0)]
    end

    elapsed = @harness.stub(:capture3_with_timeout, capture) do
      @harness.read_rolaunch_ready_seconds(
        ip: "203.0.113.10",
        ssh_user: "ubuntu",
        private_key_path: "/tmp/key",
        timeout_seconds: 1,
        poll_interval: 0
      )
    end

    assert_equal 2, attempts
    assert_in_delta 2.0, elapsed, 0.001
  end

  def test_read_rolaunch_ready_seconds_raises_last_error_after_timeout
    attempts = 0
    capture = lambda do |*_command, timeout_seconds:|
      refute_nil timeout_seconds
      attempts += 1
      ["", "timing files do not exist", Status.new(false, 1)]
    end

    error = @harness.stub(:capture3_with_timeout, capture) do
      assert_raises(RuntimeError) do
        @harness.read_rolaunch_ready_seconds(
          ip: "203.0.113.10",
          ssh_user: "ubuntu",
          private_key_path: "/tmp/key",
          timeout_seconds: 0
        )
      end
    end

    assert_equal 1, attempts
    assert_includes error.message, "timing files do not exist"
  end

  def test_read_rolaunch_ready_seconds_times_out_a_stalled_ssh_command
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(Timeout::Error) do
      @harness.capture3_with_timeout(
        RbConfig.ruby,
        "-e",
        "sleep 2",
        timeout_seconds: 0.1
      )
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 1.0
  end

  def test_read_rolaunch_ready_seconds_does_not_retry_non_rolaunch_ami
    attempts = 0
    capture = lambda do |*_command, timeout_seconds:|
      refute_nil timeout_seconds
      attempts += 1
      ["", "", Status.new(false, 44)]
    end

    @harness.stub(:capture3_with_timeout, capture) do
      assert_raises(HELPER_METHODS.const_get(:RolaunchUnavailable)) do
        @harness.read_rolaunch_ready_seconds(
          ip: "203.0.113.10",
          ssh_user: "ubuntu",
          private_key_path: "/tmp/key",
          timeout_seconds: 30,
          poll_interval: 0
        )
      end
    end

    assert_equal 1, attempts
  end

  def test_root_block_device_override_preserves_ami_gp3_throughput_by_default
    image = image_with_root_throughput(400)

    mapping = @harness.root_block_device_override(
      image,
      root_iops: nil,
      root_initialization_rate: nil,
      root_throughput: nil,
      root_volume_size: nil
    )

    assert_equal 400, mapping.fetch(:ebs).fetch(:throughput)
    assert_equal 3_000, mapping.fetch(:ebs).fetch(:iops)
    refute_includes mapping.fetch(:ebs), :volume_initialization_rate
    refute_includes File.read(HELPER_PATH), "default: 750"
  end

  def test_rolaunch_summary_rejects_incomplete_measurements
    summary = @harness.summarize_rolaunch_measurements(
      [
        { rolaunch_status: "ready", rolaunch_ready_s: 9.5 },
        { rolaunch_status: "failed", rolaunch_ready_s: nil }
      ]
    )

    assert summary[:expected]
    refute summary[:complete]
    assert_equal [9.5], summary[:values]
  end

  def test_rolaunch_summary_accepts_an_ami_without_rolaunch
    summary = @harness.summarize_rolaunch_measurements(
      [
        { rolaunch_status: "absent", rolaunch_ready_s: nil },
        { rolaunch_status: "absent", rolaunch_ready_s: nil }
      ]
    )

    refute summary[:expected]
    assert summary[:complete]
    assert_empty summary[:values]
  end

  def test_rolaunch_benchmark_remains_report_only_without_limits
    @harness.verify_rolaunch_benchmark!(
      results: [{ phase: "measure", instance_id: "", rolaunch_status: "absent", rolaunch_ready_s: nil }],
      warm_runs: 0,
      measure_runs: 1
    )
  end

  def test_rolaunch_benchmark_accepts_inclusive_average_and_strict_maximum
    @harness.verify_rolaunch_benchmark!(
      results: rolaunch_benchmark_results(warm_values: [7.9], measured_values: [7.33125, 7.33125]),
      warm_runs: 1,
      measure_runs: 2,
      average_at_most: BigDecimal("7.33125"),
      max_below: BigDecimal("10")
    )
  end

  def test_rolaunch_benchmark_compares_unrounded_average
    [7.331251, 7.334].each do |value|
      error = assert_raises(RuntimeError) do
        @harness.verify_rolaunch_benchmark!(
          results: rolaunch_benchmark_results(warm_values: [7.0], measured_values: [value]),
          warm_runs: 1,
          measure_runs: 1,
          average_at_most: BigDecimal("7.33125")
        )
      end

      assert_includes error.message, "exceeds 7.33125s"
    end
  end

  def test_rolaunch_benchmark_maximum_is_strict
    passing = rolaunch_benchmark_results(warm_values: [9.0], measured_values: [9.999999])
    @harness.verify_rolaunch_benchmark!(
      results: passing,
      warm_runs: 1,
      measure_runs: 1,
      max_below: BigDecimal("10")
    )

    error = assert_raises(RuntimeError) do
      @harness.verify_rolaunch_benchmark!(
        results: rolaunch_benchmark_results(warm_values: [9.0], measured_values: [10.0]),
        warm_runs: 1,
        measure_runs: 1,
        max_below: BigDecimal("10")
      )
    end
    assert_includes error.message, "is not below 10.0s"
  end

  def test_rolaunch_benchmark_requires_exact_phases
    error = assert_raises(RuntimeError) do
      @harness.verify_rolaunch_benchmark!(
        results: rolaunch_benchmark_results(warm_values: [], measured_values: [7.0, 7.0]),
        warm_runs: 1,
        measure_runs: 1,
        average_at_most: BigDecimal("8")
      )
    end

    assert_includes error.message, "run set differs"
  end

  def test_rolaunch_benchmark_requires_unique_instance_ids
    results = rolaunch_benchmark_results(warm_values: [7.0], measured_values: [7.0])
    results.last[:instance_id] = results.first[:instance_id]

    error = assert_raises(RuntimeError) do
      @harness.verify_rolaunch_benchmark!(
        results: results,
        warm_runs: 1,
        measure_runs: 1,
        average_at_most: BigDecimal("8")
      )
    end

    assert_includes error.message, "unique nonempty instance ID"
  end

  def test_rolaunch_benchmark_requires_ready_warm_and_measured_results
    results = rolaunch_benchmark_results(warm_values: [7.0], measured_values: [7.0])
    results.first[:rolaunch_status] = "failed"
    results.first[:rolaunch_ready_s] = nil

    error = assert_raises(RuntimeError) do
      @harness.verify_rolaunch_benchmark!(
        results: results,
        warm_runs: 1,
        measure_runs: 1,
        max_below: BigDecimal("10")
      )
    end

    assert_includes error.message, results.first[:instance_id]
  end

  def test_rolaunch_benchmark_cli_exposes_and_validates_optional_limits
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, HELPER_PATH, "--help")
    assert status.success?, stderr
    assert_includes stdout, "--require-average-rolaunch-ready-at-most"
    assert_includes stdout, "--require-max-rolaunch-ready-below"
    assert_includes stdout, "--verify-compact-recovery"

    %w[invalid 0 -1 NaN Infinity].each do |value|
      _stdout, invalid_stderr, invalid_status = Open3.capture3(
        RbConfig.ruby,
        HELPER_PATH,
        "ami-test",
        "--require-average-rolaunch-ready-at-most",
        value
      )
      refute invalid_status.success?, value
      assert_includes invalid_stderr, "must be a finite positive number", value
    end
  end

  def test_root_block_device_override_uses_explicit_gp3_throughput
    image = image_with_root_throughput(400)

    mapping = @harness.root_block_device_override(
      image,
      root_iops: nil,
      root_initialization_rate: nil,
      root_throughput: 500,
      root_volume_size: nil
    )

    assert_equal 500, mapping.fetch(:ebs).fetch(:throughput)
  end

  def test_root_block_device_override_uses_explicit_gp3_iops
    image = image_with_root_throughput(400)

    mapping = @harness.root_block_device_override(
      image,
      root_iops: 16_000,
      root_initialization_rate: nil,
      root_throughput: nil,
      root_volume_size: nil
    )

    assert_equal 16_000, mapping.fetch(:ebs).fetch(:iops)
    assert_equal 400, mapping.fetch(:ebs).fetch(:throughput)
  end

  def test_root_block_device_override_sets_provisioned_initialization_rate
    image = image_with_root_throughput(400)

    mapping = @harness.root_block_device_override(
      image,
      root_iops: 3_000,
      root_initialization_rate: 300,
      root_throughput: 400,
      root_volume_size: 30
    )

    assert_equal 300, mapping.fetch(:ebs).fetch(:volume_initialization_rate)
    api_shape = Aws::EC2::Client.api.operation(:run_instances)
      .input.shape.member(:block_device_mappings)
      .shape.member.shape.member(:ebs).shape
    assert_includes api_shape.members.map(&:first), :volume_initialization_rate
  end

  def test_root_volume_initialization_status_records_effective_configuration
    ec2 = stub_volume_inspection_client

    details = @harness.root_volume_initialization_status(
      ec2: ec2,
      instance_id: "i-test",
      root_device_name: "/dev/sda1"
    )

    assert_equal "vol-test", details[:volume_id]
    assert_equal "gp3", details[:volume_type]
    assert_equal 30, details[:size_gib]
    assert_equal 3_000, details[:iops]
    assert_equal 400, details[:throughput_mibps]
    assert_equal "snap-test", details[:snapshot_id]
    assert_equal 300, details[:provisioned_rate_mibps]
    assert_equal "provisioned-rate", details[:initialization_type]
    assert_equal 25, details[:progress_percent]
    assert_equal 60, details[:estimated_seconds_remaining]
  end

  def test_root_volume_initialization_status_keeps_effective_configuration_when_status_fails
    ec2 = stub_volume_inspection_client
    ec2.stub_responses(:describe_volume_status, "UnauthorizedOperation")

    details = @harness.root_volume_initialization_status(
      ec2: ec2,
      instance_id: "i-test",
      root_device_name: "/dev/sda1"
    )

    assert_equal 300, details[:provisioned_rate_mibps]
    assert_equal 400, details[:throughput_mibps]
    assert_includes details[:initialization_status_error], "UnauthorizedOperation"
  end

  def test_root_volume_initialization_status_fails_clearly_when_mapping_is_missing
    ec2 = Aws::EC2::Client.new(stub_responses: true)
    ec2.stub_responses(:describe_instances, reservations: [{ instances: [{ block_device_mappings: [] }] }])

    error = assert_raises(RuntimeError) do
      @harness.root_volume_initialization_status(
        ec2: ec2,
        instance_id: "i-test",
        root_device_name: "/dev/sda1"
      )
    end

    assert_includes error.message, "Unable to find root volume mapping"
    assert_includes error.message, "i-test"
  end

  def test_verify_root_volume_configuration_accepts_matching_requested_values
    details = { provisioned_rate_mibps: 300, throughput_mibps: 400 }

    @harness.verify_root_volume_configuration!(
      details,
      requested_initialization_rate: 300,
      requested_throughput: 400
    )
  end

  def test_verify_root_volume_configuration_rejects_initialization_rate_mismatch
    details = { provisioned_rate_mibps: nil, throughput_mibps: 400 }

    error = assert_raises(RuntimeError) do
      @harness.verify_root_volume_configuration!(
        details,
        requested_initialization_rate: 300,
        requested_throughput: 400
      )
    end

    assert_includes error.message, "initialization rate mismatch"
  end

  def test_verify_root_volume_configuration_rejects_throughput_mismatch
    details = { provisioned_rate_mibps: 300, throughput_mibps: 125 }

    error = assert_raises(RuntimeError) do
      @harness.verify_root_volume_configuration!(
        details,
        requested_initialization_rate: 300,
        requested_throughput: 400
      )
    end

    assert_includes error.message, "throughput mismatch"
  end

  def test_linux_user_data_records_common_ready_marker_after_starting_ssh
    user_data = @harness.linux_user_data(ssh_user: "ubuntu", public_key: "ssh-rsa test")

    assert_operator user_data.index("runs-on-boot-benchmark-ready"), :>, user_data.index("systemctl start ssh.service")
  end

  def test_root_block_device_override_uses_explicit_volume_size
    image = image_with_root_throughput(400)

    mapping = @harness.root_block_device_override(
      image,
      root_iops: 20_000,
      root_initialization_rate: nil,
      root_throughput: 400,
      root_volume_size: 40
    )

    assert_equal 40, mapping.fetch(:ebs).fetch(:volume_size)
    assert_equal 20_000, mapping.fetch(:ebs).fetch(:iops)
  end

  def test_security_group_setup_rolls_back_when_ingress_authorization_fails
    ec2 = Aws::EC2::Client.new(stub_responses: true)
    ec2.stub_responses(:create_security_group, group_id: "sg-test")
    ec2.stub_responses(:authorize_security_group_ingress, "UnauthorizedOperation")
    ec2.stub_responses(:delete_security_group, {})
    subnet = Struct.new(:vpc_id).new("vpc-test")

    assert_raises(Aws::EC2::Errors::ServiceError) do
      @harness.create_temp_security_group(ec2, subnet, "203.0.113.10")
    end

    operations = ec2.api_requests.map { |request| request.fetch(:operation_name) }
    assert_equal %i[create_security_group authorize_security_group_ingress delete_security_group], operations
  end

  def test_measurement_instances_tag_their_root_volumes
    ec2 = Aws::EC2::Client.new(stub_responses: true)
    ec2.stub_responses(:run_instances, instances: [{ instance_id: "i-test" }])
    subnet = Struct.new(:subnet_id).new("subnet-test")

    @harness.launch_instance(
      ec2: ec2,
      image: image_with_root_throughput(400),
      instance_type: "m8a.large",
      subnet: subnet,
      security_group_id: "sg-test",
      user_data: "#!/bin/bash\n",
      root_iops: 3_000,
      root_initialization_rate: 300,
      root_throughput: 400,
      root_volume_size: 30
    )

    request = ec2.api_requests.find { |candidate| candidate.fetch(:operation_name) == :run_instances }
    volume_tags = request.fetch(:params).fetch(:tag_specifications).find do |specification|
      specification.fetch(:resource_type) == "volume"
    end
    refute_nil volume_tags
    assert_includes volume_tags.fetch(:tags), { key: "Name", value: "measure-launch-time" }
    assert_includes volume_tags.fetch(:tags), { key: "application", value: "RunsOn" }
  end

  def test_profile_boot_remote_script_is_valid_shell_and_includes_boot_timing_diagnostics
    source = File.read(PROFILE_HELPER_PATH)
    fragment = source[/^analyze_prefix = .*?(?=^Dir\.mktmpdir)/m]
    raise "unable to locate profile-boot remote script" unless fragment

    context = binding
    context.local_variable_set(:options, { ssh_user: "ubuntu" })
    context.eval(fragment, PROFILE_HELPER_PATH, source[0, source.index(fragment)].count("\n") + 1)
    remote_script = context.local_variable_get(:remote_script)

    _stdout, stderr, status = Open3.capture3("bash", "-n", stdin_data: remote_script)

    assert status.success?, stderr
    assert_includes remote_script, "=== boot configuration ==="
    assert_includes remote_script, "/etc/default/grub.d/40-force-partuuid.cfg"
    assert_includes remote_script, "ExecMainExitTimestampMonotonic"
    assert_includes remote_script, "=== rolaunch timings ==="
    assert_includes remote_script, "/var/lib/rolaunch/timings.json"
    assert_includes remote_script, "=== runner readiness ==="
    assert_includes remote_script, "amazon-ssm-agent.service"
    assert_includes remote_script, "sudo -n docker info"
    assert_includes source, "root_throughput || root.ebs.throughput"
    assert_includes source, "capture3_with_timeout(*ssh_cmd, timeout_seconds: timeout_seconds)"
    assert_includes source, "cleanup_profile_resources(ec2, instance_id, security_group_id)"
    assert_match(/additional_block_device_mappings.*?delete_on_termination: true/m, source)
    refute_includes source, "default: 750"
  end

  def test_instance_termination_requests_are_nonblocking_and_waited_for_as_a_batch
    client = FakeTerminationClient.new

    @harness.request_instance_termination(client, "i-first")
    @harness.request_instance_termination(client, "i-second")

    assert_equal [["i-first"], ["i-second"]], client.termination_requests
    assert_empty client.wait_requests

    @harness.wait_for_instances_terminated(client, %w[i-first i-second])

    assert_equal [[:instance_terminated, %w[i-first i-second]]], client.wait_requests
  end

  def test_terminate_instance_and_wait_prevents_launch_overlap
    client = FakeTerminationClient.new

    @harness.terminate_instance_and_wait(client, "i-first")

    assert_equal [["i-first"]], client.termination_requests
    assert_equal [[:instance_terminated, ["i-first"]]], client.wait_requests
  end

  def test_wait_for_instances_terminated_skips_empty_batches
    client = FakeTerminationClient.new

    @harness.wait_for_instances_terminated(client, [])

    assert_empty client.wait_requests
  end

  def test_cleanup_instances_continues_after_each_failure
    client = FakeTerminationClient.new(fail_termination_for: "i-first", fail_wait: true)

    errors = @harness.cleanup_instances(client, %w[i-first i-second])

    assert_equal [["i-first"], ["i-second"]], client.termination_requests
    assert_equal [[:instance_terminated, ["i-second"]]], client.wait_requests
    assert_equal 2, errors.length
    assert_includes errors.first, "i-first"
    assert_includes errors.last, "waiting"
  end

  private

  def rolaunch_benchmark_results(warm_values:, measured_values:)
    (warm_values.map { |value| ["warm", value] } + measured_values.map { |value| ["measure", value] }).each_with_index.map do |(phase, value), index|
      {
        phase: phase,
        instance_id: "i-benchmark-#{index}",
        rolaunch_status: "ready",
        rolaunch_ready_s: value
      }
    end
  end

  def stub_volume_inspection_client
    ec2 = Aws::EC2::Client.new(stub_responses: true)
    ec2.stub_responses(
      :describe_instances,
      reservations: [
        {
          instances: [
            {
              block_device_mappings: [
                { device_name: "/dev/sda1", ebs: { volume_id: "vol-test" } }
              ]
            }
          ]
        }
      ]
    )
    ec2.stub_responses(
      :describe_volumes,
      volumes: [
        {
          volume_id: "vol-test",
          volume_type: "gp3",
          size: 30,
          iops: 3_000,
          throughput: 400,
          snapshot_id: "snap-test",
          volume_initialization_rate: 300
        }
      ]
    )
    ec2.stub_responses(
      :describe_volume_status,
      volume_statuses: [
        {
          volume_id: "vol-test",
          initialization_status_details: {
            initialization_type: "provisioned-rate",
            progress: 25,
            estimated_time_to_complete_in_seconds: 60
          }
        }
      ]
    )
    ec2
  end

  def image_with_root_throughput(throughput)
    root = BlockMapping.new(
      device_name: "/dev/sda1",
      ebs: EbsMapping.new(volume_size: 30, volume_type: "gp3", iops: 3_000, throughput: throughput)
    )
    Image.new(image_id: "ami-test", root_device_name: "/dev/sda1", block_device_mappings: [root])
  end

  def rolaunch_output(done_at: nil, steps: nil)
    steps ||= [
      { "Name" => "rolaunch.started", "Time" => "2026-08-03T01:02:04Z" },
      { "Name" => "rolaunch.done", "Time" => done_at }
    ]
    <<~OUTPUT
      {"pendingTime":"2026-08-03T01:02:03Z"}

      ---ROLAUNCH-TIMINGS---
      #{JSON.generate(steps)}
    OUTPUT
  end
end
