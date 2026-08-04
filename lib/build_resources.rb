# frozen_string_literal: true

module BuildResources
  COMPACT_ROOT_ARCHITECTURE = "x86_64"
  COMPACT_ROOT_BOOT_MODE = "uefi-preferred"
  COMPACT_ROOT_DEVICE_NAME = "/dev/sda1"
  COMPACT_ROOT_IOPS = 3_000
  SNAPSHOT_DELETE_RETRY_DELAYS = [1, 2, 4, 8, 16, 30, 60, 60].freeze

  module_function

  def exact_tag?(resource, key, value)
    Array(resource.tags).any? { |tag| tag.key == key && tag.value == value }
  end

  def exact_build_images(ec2_client:, ami_name:, require_ami_name_tag:)
    filters = [{ name: "name", values: [ami_name] }]
    filters << { name: "tag:ami_name", values: [ami_name] } if require_ami_name_tag
    response = ec2_client.describe_images(
      owners: ["self"],
      filters: filters
    )

    response.images.select do |image|
      image.name == ami_name && (!require_ami_name_tag || exact_tag?(image, "ami_name", ami_name))
    end
  end

  def find_exact_build_image(ec2_client:, ami_name:, require_ami_name_tag:)
    images = exact_build_images(
      ec2_client: ec2_client,
      ami_name: ami_name,
      require_ami_name_tag: require_ami_name_tag
    )
    identity = require_ami_name_tag ? "exact name and ami_name tag" : "exact name"
    fail("No self-owned AMI found with #{identity} #{ami_name}") if images.empty?
    fail("Multiple self-owned AMIs found with #{identity} #{ami_name}") if images.length > 1

    images.first
  end

  def validate_compact_image!(
    ec2_client:,
    image:,
    limit_gib:,
    expected_volume_size_gib:,
    expected_throughput_mibps:,
    output: $stdout
  )
    fail("Compact snapshot limit must be a positive number of GiB") unless limit_gib.positive?
    unless expected_volume_size_gib&.positive? && expected_throughput_mibps&.positive?
      fail("Compact AMI volume size and throughput must be positive")
    end

    expected_image_values = {
      architecture: COMPACT_ROOT_ARCHITECTURE,
      boot_mode: COMPACT_ROOT_BOOT_MODE,
      ena_support: true,
      imds_support: "v2.0",
      root_device_name: COMPACT_ROOT_DEVICE_NAME
    }
    expected_image_values.each do |attribute, expected|
      actual = image.public_send(attribute)
      next if actual == expected

      fail("Compact AMI #{image.image_id} has #{attribute}=#{actual.inspect}; expected #{expected.inspect}")
    end

    limit_bytes = limit_gib * 1024 * 1024 * 1024
    mappings = Array(image.block_device_mappings).select { |mapping| mapping.ebs&.snapshot_id }
    unless mappings.length == 1 && mappings.first.device_name == image.root_device_name
      fail("Compact AMI #{image.image_id} must contain exactly one snapshot-backed root mapping")
    end

    root_ebs = mappings.first.ebs
    expected_root_values = {
      volume_size: expected_volume_size_gib,
      volume_type: "gp3",
      iops: COMPACT_ROOT_IOPS,
      throughput: expected_throughput_mibps
    }
    expected_root_values.each do |attribute, expected|
      actual = root_ebs.public_send(attribute)
      next if actual == expected

      fail("Compact AMI #{image.image_id} root has #{attribute}=#{actual.inspect}; expected #{expected.inspect}")
    end

    output.puts(
      "Compact AMI #{image.image_id} contract: #{image.boot_mode}, #{image.architecture}, " \
      "ENA=#{image.ena_support}, IMDS=#{image.imds_support}, root=#{image.root_device_name}, " \
      "#{root_ebs.volume_type} #{root_ebs.volume_size} GiB/#{root_ebs.iops} IOPS/#{root_ebs.throughput} MiB/s"
    )

    snapshot_id = root_ebs.snapshot_id
    snapshots = ec2_client.describe_snapshots(snapshot_ids: [snapshot_id]).snapshots
    snapshot = snapshots.find { |candidate| candidate.snapshot_id == snapshot_id }
    fail("Compact root snapshot #{snapshot_id} was not found") unless snapshot

    size_bytes = snapshot.full_snapshot_size_in_bytes
    fail("Compact root snapshot #{snapshot_id} did not report FullSnapshotSizeInBytes") if size_bytes.nil?
    fail("Compact root snapshot #{snapshot_id} has invalid FullSnapshotSizeInBytes=#{size_bytes}") unless size_bytes.positive?

    size_gib = size_bytes.fdiv(1024 * 1024 * 1024)
    output.puts format(
      "Compact root snapshot %s contains %.2f GiB (%d bytes) of blocks; required limit is <%g GiB",
      snapshot_id,
      size_gib,
      size_bytes,
      limit_gib
    )
    return size_bytes if size_bytes < limit_bytes

    fail(format(
      "Compact root snapshot %s contains %.2f GiB of blocks, exceeding the required <%g GiB limit",
      snapshot_id,
      size_gib,
      limit_gib
    ))
  end

  def find_and_validate_build_image!(
    ec2_client:,
    ami_name:,
    compact_snapshot_limit_gib: nil,
    compact_root_volume_size_gib: nil,
    compact_root_throughput_mibps: nil,
    output: $stdout,
    sleeper: Kernel.method(:sleep)
  )
    compact_root = !compact_snapshot_limit_gib.nil?
    image = find_exact_build_image(
      ec2_client: ec2_client,
      ami_name: ami_name,
      require_ami_name_tag: compact_root
    )
    if compact_root
      validate_compact_image!(
        ec2_client: ec2_client,
        image: image,
        limit_gib: compact_snapshot_limit_gib,
        expected_volume_size_gib: compact_root_volume_size_gib,
        expected_throughput_mibps: compact_root_throughput_mibps,
        output: output
      )
    end
    image
  rescue StandardError
    if compact_root
      cleanup_failed_build(
        ec2_client: ec2_client,
        ami_name: ami_name,
        require_ami_name_tag: true,
        output: output,
        sleeper: sleeper
      )
    end
    raise
  end

  def cleanup_failed_build(ec2_client:, ami_name:, require_ami_name_tag:, output: $stdout, sleeper: Kernel.method(:sleep))
    errors = []

    instances = cleanup_query(errors, output, "find tagged instances") do
      ec2_client.describe_instances(
        filters: [
          { name: "instance-state-name", values: %w[pending running stopping stopped] },
          { name: "tag:ami_name", values: [ami_name] }
        ]
      ).reservations.flat_map(&:instances).select do |instance|
        exact_tag?(instance, "ami_name", ami_name)
      end
    end || []
    instances.each do |instance|
      cleanup_action(errors, output, "terminate instance #{instance.instance_id}") do
        ec2_client.terminate_instances(instance_ids: [instance.instance_id])
      end
    end
    unless instances.empty?
      cleanup_action(errors, output, "wait for tagged instances to terminate") do
        ec2_client.wait_until(
          :instance_terminated,
          { instance_ids: instances.map(&:instance_id) },
          { delay: 5, max_attempts: 60 }
        )
      end
    end

    images = cleanup_query(errors, output, "find exact partial AMIs") do
      exact_build_images(
        ec2_client: ec2_client,
        ami_name: ami_name,
        require_ami_name_tag: require_ami_name_tag
      )
    end || []

    tagged_snapshots = cleanup_query(errors, output, "find tagged snapshots") do
      ec2_client.describe_snapshots(
        owner_ids: ["self"],
        filters: [{ name: "tag:ami_name", values: [ami_name] }]
      ).snapshots.select { |snapshot| exact_tag?(snapshot, "ami_name", ami_name) }
    end || []
    snapshot_ids = tagged_snapshots.map(&:snapshot_id)
    atomically_deleted_snapshot_ids = []
    retry_snapshot_ids = []
    skipped_snapshot_ids = []

    images.each do |image|
      referenced_snapshot_ids = Array(image.block_device_mappings).filter_map do |mapping|
        mapping.ebs&.snapshot_id
      end
      deregister_result = nil
      deregistered = cleanup_action(errors, output, "deregister AMI #{image.image_id}") do
        deregister_result = ec2_client.deregister_image(
          image_id: image.image_id,
          delete_associated_snapshots: true
        )
        fail("EC2 returned an unsuccessful result") unless deregister_result[:return]
      end
      next unless deregistered

      deletion_results = Array(deregister_result.delete_snapshot_results)
      deletion_results.each do |result|
        case result.return_code
        when "success"
          atomically_deleted_snapshot_ids << result.snapshot_id
        when "skipped"
          skipped_snapshot_ids << result.snapshot_id
        else
          retry_snapshot_ids << result.snapshot_id
          output.puts(
            "Cleanup: atomic deletion of snapshot #{result.snapshot_id} returned #{result.return_code}; retrying separately"
          )
        end
      end
      reported_snapshot_ids = deletion_results.map(&:snapshot_id)
      retry_snapshot_ids.concat(referenced_snapshot_ids - reported_snapshot_ids)
    end

    volumes = cleanup_query(errors, output, "find available tagged volumes") do
      ec2_client.describe_volumes(
        filters: [
          { name: "status", values: ["available"] },
          { name: "tag:ami_name", values: [ami_name] }
        ]
      ).volumes.select { |volume| exact_tag?(volume, "ami_name", ami_name) }
    end || []
    volumes.each do |volume|
      cleanup_action(errors, output, "delete volume #{volume.volume_id}") do
        ec2_client.delete_volume(volume_id: volume.volume_id)
      end
    end

    atomically_deleted_snapshot_ids.uniq!
    retry_snapshot_ids = retry_snapshot_ids.uniq - atomically_deleted_snapshot_ids
    skipped_snapshot_ids = skipped_snapshot_ids.uniq - atomically_deleted_snapshot_ids - retry_snapshot_ids
    skipped_snapshot_ids.each do |snapshot_id|
      record_cleanup_error(
        errors,
        output,
        "delete snapshot #{snapshot_id}",
        RuntimeError.new("EC2 skipped atomic deletion because the snapshot remains associated with another AMI")
      )
    end

    snapshot_ids = (snapshot_ids + retry_snapshot_ids).uniq - atomically_deleted_snapshot_ids - skipped_snapshot_ids
    snapshot_ids.each do |snapshot_id|
      cleanup_action_with_retry(errors, output, "delete snapshot #{snapshot_id}", sleeper: sleeper) do
        ec2_client.delete_snapshot(snapshot_id: snapshot_id)
      end
    end

    errors
  end

  def cleanup_query(errors, output, description)
    yield
  rescue StandardError => e
    record_cleanup_error(errors, output, description, e)
    nil
  end
  private_class_method :cleanup_query

  def cleanup_action(errors, output, description)
    output.puts("Cleanup: #{description}")
    yield
    true
  rescue StandardError => e
    record_cleanup_error(errors, output, description, e)
    false
  end
  private_class_method :cleanup_action

  def cleanup_action_with_retry(errors, output, description, sleeper:)
    attempts = 0
    begin
      attempts += 1
      max_attempts = SNAPSHOT_DELETE_RETRY_DELAYS.length + 1
      output.puts("Cleanup: #{description} (attempt #{attempts}/#{max_attempts})")
      yield
      true
    rescue StandardError => e
      if attempts <= SNAPSHOT_DELETE_RETRY_DELAYS.length
        output.puts("Cleanup retry for #{description}: #{e.class}: #{e.message}")
        sleeper.call(SNAPSHOT_DELETE_RETRY_DELAYS.fetch(attempts - 1))
        retry
      end

      record_cleanup_error(errors, output, description, e)
      false
    end
  end
  private_class_method :cleanup_action_with_retry

  def record_cleanup_error(errors, output, description, error)
    message = "Cleanup failed to #{description}: #{error.class}: #{error.message}"
    output.puts(message)
    errors << message
  end
  private_class_method :record_cleanup_error
end
