require "minitest/autorun"
require "aws-sdk-ec2"
require "aws-sdk-ssm"
require "base64"

class MeasureWindowsLaunchTimeTest < Minitest::Test
  HELPER_PATH = File.expand_path("../bin/utils/measure-windows-launch-time", __dir__)
  METHODS = Module.new.tap do |mod|
    source = File.read(HELPER_PATH)
    methods = source[/^def find_latest_windows_ami.*?(?=^ec2 =)/m]
    raise "unable to locate helper methods" unless methods

    mod.module_eval(methods, HELPER_PATH, source[0, source.index(methods)].count("\n") + 1)
  end

  class Harness
    include METHODS
  end

  Ebs = Struct.new(:volume_size, :iops, keyword_init: true)
  Mapping = Struct.new(:device_name, :ebs, keyword_init: true)
  Image = Struct.new(:image_id, :root_device_name, :block_device_mappings, keyword_init: true)

  def setup
    @harness = Harness.new
  end

  def test_defaults_require_200_mibps_initialization_and_400_mibps_throughput
    source = File.read(HELPER_PATH)

    assert_match(/--root-initialization-rate.*default: 200/, source)
    assert_match(/--root-throughput.*default: 400/, source)
    assert_match(/under_60_seconds: values\.all\? \{ \|value\| value < 60 \}/, source)
    assert_includes source, "--diagnostics-s3-uri"
    assert_includes source, "--full-stack-smoke-script"
  end

  def test_windows_ready_time_uses_latest_console_message
    output = <<~LOG
      2026/08/06 11:10:01Z: Message: Windows is Ready to use
      2026/08/06 11:12:34Z: Message: Windows is Ready to use
    LOG

    assert_equal Time.utc(2026, 8, 6, 11, 12, 34), @harness.windows_ready_time(output)
  end

  def test_console_milestone_time_uses_latest_matching_message
    output = <<~LOG
      2026/08/06 11:10:01Z: Windows sysprep configuration complete.
      2026/08/06 11:10:04Z: Windows sysprep configuration complete.
    LOG

    assert_equal Time.utc(2026, 8, 6, 11, 10, 4),
      @harness.console_milestone_time(output, "Windows sysprep configuration complete")
  end

  def test_decodes_sdk_console_payload
    output = "2026/08/06 11:12:34Z: Message: Windows is Ready to use\n"

    assert_equal output, @harness.decode_console_output(Base64.strict_encode64(output))
  end

  def test_root_mapping_provisions_required_storage_rates
    image = Image.new(
      image_id: "ami-test",
      root_device_name: "/dev/sda1",
      block_device_mappings: [Mapping.new(device_name: "/dev/sda1", ebs: Ebs.new(volume_size: 30, iops: 3_000))]
    )

    mapping = @harness.root_mapping(image, initialization_rate: 200, throughput: 400)

    assert_equal 200, mapping.fetch(:ebs).fetch(:volume_initialization_rate)
    assert_equal 400, mapping.fetch(:ebs).fetch(:throughput)
    assert_equal "gp3", mapping.fetch(:ebs).fetch(:volume_type)
  end

  def test_launch_request_carries_required_storage_rates
    ec2 = Aws::EC2::Client.new(stub_responses: true)
    ec2.stub_responses(:run_instances, instances: [{ instance_id: "i-test", launch_time: Time.now }])
    image = Image.new(
      image_id: "ami-test",
      root_device_name: "/dev/sda1",
      block_device_mappings: [Mapping.new(device_name: "/dev/sda1", ebs: Ebs.new(volume_size: 30, iops: 3_000))]
    )

    @harness.launch_instance(
      ec2: ec2,
      image: image,
      instance_type: "m8i.xlarge",
      subnet_id: "subnet-test",
      security_group_id: "sg-test",
      initialization_rate: 200,
      throughput: 400,
      phase: "measure",
      nested_virtualization: "enabled",
      iam_instance_profile: "SSMInstanceProfile",
      user_data: Base64.strict_encode64("<powershell># descriptor</powershell>")
    )

    request = ec2.api_requests.find { |candidate| candidate.fetch(:operation_name) == :run_instances }
    ebs = request.fetch(:params).fetch(:block_device_mappings).first.fetch(:ebs)
    assert_equal 200, ebs.fetch(:volume_initialization_rate)
    assert_equal 400, ebs.fetch(:throughput)
    assert_equal "enabled", request.fetch(:params).fetch(:cpu_options).fetch(:nested_virtualization)
    assert_equal "SSMInstanceProfile", request.fetch(:params).fetch(:iam_instance_profile).fetch(:name)
    assert_equal Base64.strict_encode64("<powershell># descriptor</powershell>"), request.fetch(:params).fetch(:user_data)
  end

  def test_launch_service_milestones_require_runs_on_before_ssm
    launch_time = Time.utc(2026, 8, 6, 11, 10, 0)
    state = {
      status: "bootstrap-running",
      milestones: [
        { name: "runs-on-launch.bootstrap-started", time: "2026-08-06T11:10:10Z" },
        { name: "runs-on-launch.ssm-started", time: "2026-08-06T11:10:11Z" }
      ]
    }
    ssm = Aws::SSM::Client.new(stub_responses: true)
    ssm.stub_responses(:describe_instance_information, instance_information_list: [{ ping_status: "Online" }])
    ssm.stub_responses(:send_command, command: { command_id: "command-test" })
    ssm.stub_responses(:get_command_invocation, status: "Success", standard_output_content: JSON.generate(state))

    result = @harness.launch_service_milestones(ssm, instance_id: "i-test", launch_time: launch_time, timeout_seconds: 1)

    assert_equal 10.0, result.fetch("milestones").fetch("runs-on-launch.bootstrap-started").fetch("seconds")
    assert_equal 11.0, result.fetch("milestones").fetch("runs-on-launch.ssm-started").fetch("seconds")
  end

  def test_ssm_command_retries_until_invocation_is_visible
    ssm = Aws::SSM::Client.new(stub_responses: true)
    ssm.stub_responses(:send_command, command: { command_id: "command-test" })
    ssm.stub_responses(
      :get_command_invocation,
      "InvocationDoesNotExist",
      { status: "Success", standard_output_content: "ready" }
    )
    @harness.define_singleton_method(:sleep) { |_seconds| }

    assert_equal "ready", @harness.run_ssm_powershell(
      ssm,
      instance_id: "i-test",
      command: "Write-Output ready",
      timeout_seconds: 1
    )
  end

  def test_full_stack_smoke_enables_nested_and_container_checks
    summary = { "Success" => true, "Checks" => 47, "FailedChecks" => [] }
    ssm = Aws::SSM::Client.new(stub_responses: true)
    ssm.stub_responses(:send_command, command: { command_id: "command-test" })
    ssm.stub_responses(:get_command_invocation, status: "Success", standard_output_content: "RUNS_ON_FULL_STACK:#{JSON.generate(summary)}")

    result = @harness.run_full_stack_smoke(
      ssm,
      instance_id: "i-test",
      script_path: File.expand_path("../bin/utils/windows-full-stack-smoke.ps1", __dir__),
      nested_virtualization: "enabled",
      timeout_seconds: 1
    )

    request = ssm.api_requests.find { |candidate| candidate.fetch(:operation_name) == :send_command }
    command = request.fetch(:params).fetch(:parameters).fetch("commands").first
    assert_includes command, "-NestedVirtualization 'Enabled' -RunWindowsContainer"
    assert_equal summary, result
  end

  def test_full_stack_smoke_rejects_failed_summary
    summary = { "Success" => false, "Checks" => 47, "FailedChecks" => ["Operational:Chrome"] }
    ssm = Aws::SSM::Client.new(stub_responses: true)
    ssm.stub_responses(:send_command, command: { command_id: "command-test" })
    ssm.stub_responses(:get_command_invocation, status: "Success", standard_output_content: "RUNS_ON_FULL_STACK:#{JSON.generate(summary)}")

    error = assert_raises(RuntimeError) do
      @harness.run_full_stack_smoke(
        ssm,
        instance_id: "i-test",
        script_path: File.expand_path("../bin/utils/windows-full-stack-smoke.ps1", __dir__),
        nested_virtualization: "enabled",
        timeout_seconds: 1
      )
    end

    assert_includes error.message, "Operational:Chrome"
  end
end
