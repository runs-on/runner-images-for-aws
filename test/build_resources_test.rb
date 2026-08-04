require "minitest/autorun"
require "ostruct"
require "stringio"

require_relative "../lib/build_resources"

class BuildResourcesTest < Minitest::Test
  Tag = Struct.new(:key, :value, keyword_init: true)
  Ebs = Struct.new(:snapshot_id, keyword_init: true)
  Mapping = Struct.new(:device_name, :ebs, keyword_init: true)
  Resource = Struct.new(
    :instance_id,
    :image_id,
    :name,
    :root_device_name,
    :block_device_mappings,
    :snapshot_id,
    :full_snapshot_size_in_bytes,
    :volume_id,
    :tags,
    keyword_init: true
  )

  class FakeEc2
    attr_reader :events, :requests, :snapshot_delete_attempts

    def initialize(instances: [], images: [], snapshots: [], volumes: [], fail_snapshot_once: nil)
      @instances = instances
      @images = images
      @snapshots = snapshots
      @volumes = volumes
      @fail_snapshot_once = fail_snapshot_once
      @events = []
      @requests = {}
      @snapshot_delete_attempts = Hash.new(0)
    end

    def describe_instances(params)
      @requests[:describe_instances] = params
      @events << :describe_instances
      OpenStruct.new(reservations: [OpenStruct.new(instances: @instances)])
    end

    def terminate_instances(instance_ids:)
      @events << [:terminate_instances, instance_ids]
      OpenStruct.new
    end

    def wait_until(waiter_name, params, options)
      @events << [:wait_until, waiter_name, params, options]
      OpenStruct.new
    end

    def describe_images(params)
      @requests[:describe_images] = params
      @events << :describe_images
      OpenStruct.new(images: @images)
    end

    def deregister_image(image_id:)
      @events << [:deregister_image, image_id]
      OpenStruct.new
    end

    def describe_snapshots(params)
      @requests[:describe_snapshots] = params
      @events << :describe_snapshots
      selected = if params.key?(:snapshot_ids)
                   @snapshots.select { |snapshot| params.fetch(:snapshot_ids).include?(snapshot.snapshot_id) }
                 else
                   @snapshots
                 end
      OpenStruct.new(snapshots: selected)
    end

    def delete_snapshot(snapshot_id:)
      @snapshot_delete_attempts[snapshot_id] += 1
      @events << [:delete_snapshot, snapshot_id]
      if snapshot_id == @fail_snapshot_once && @snapshot_delete_attempts[snapshot_id] == 1
        raise "snapshot is still in use"
      end

      OpenStruct.new
    end

    def describe_volumes(params)
      @requests[:describe_volumes] = params
      @events << :describe_volumes
      OpenStruct.new(volumes: @volumes)
    end

    def delete_volume(volume_id:)
      @events << [:delete_volume, volume_id]
      OpenStruct.new
    end
  end

  def tag(name, value)
    Tag.new(key: name, value: value)
  end

  def image(name:, tag_value: name, snapshot_id: "snap-root", size_bytes: nil)
    Resource.new(
      image_id: "ami-exact",
      name: name,
      root_device_name: "/dev/sda1",
      block_device_mappings: [
        Mapping.new(device_name: "/dev/sda1", ebs: Ebs.new(snapshot_id: snapshot_id))
      ],
      tags: tag_value.nil? ? [] : [tag("ami_name", tag_value)],
      full_snapshot_size_in_bytes: size_bytes
    )
  end

  def test_cleanup_waits_and_deletes_only_exact_build_resources
    ami_name = "runs-on-ubuntu26-full-x64-123"
    exact_image = image(name: ami_name, snapshot_id: "snap-image")
    wrong_image = image(name: "other", tag_value: ami_name, snapshot_id: "snap-wrong")
    exact_instance = Resource.new(instance_id: "i-exact", tags: [tag("ami_name", ami_name)])
    wrong_instance = Resource.new(instance_id: "i-wrong", tags: [tag("ami_name", "other")])
    exact_volume = Resource.new(volume_id: "vol-exact", tags: [tag("ami_name", ami_name)])
    wrong_volume = Resource.new(volume_id: "vol-wrong", tags: [tag("ami_name", "other")])
    exact_snapshot = Resource.new(snapshot_id: "snap-orphan", tags: [tag("ami_name", ami_name)])
    wrong_snapshot = Resource.new(snapshot_id: "snap-wrong", tags: [tag("ami_name", "other")])
    client = FakeEc2.new(
      instances: [exact_instance, wrong_instance],
      images: [exact_image, wrong_image],
      snapshots: [exact_snapshot, wrong_snapshot],
      volumes: [exact_volume, wrong_volume],
      fail_snapshot_once: "snap-image"
    )
    sleep_delays = []

    errors = BuildResources.cleanup_failed_build(
      ec2_client: client,
      ami_name: ami_name,
      require_ami_name_tag: true,
      output: StringIO.new,
      sleeper: ->(delay) { sleep_delays << delay }
    )

    assert_empty errors
    assert_includes client.events, [:terminate_instances, ["i-exact"]]
    refute_includes client.events, [:terminate_instances, ["i-wrong"]]
    wait_event = [
      :wait_until,
      :instance_terminated,
      { instance_ids: ["i-exact"] },
      { delay: 5, max_attempts: 60 }
    ]
    assert_includes client.events, wait_event
    assert_operator client.events.index(wait_event), :<,
                    client.events.index(:describe_volumes)
    assert_includes client.events, [:deregister_image, "ami-exact"]
    assert_includes client.events, [:delete_volume, "vol-exact"]
    refute_includes client.events, [:delete_volume, "vol-wrong"]
    assert_equal 1, client.snapshot_delete_attempts.fetch("snap-orphan")
    assert_equal 2, client.snapshot_delete_attempts.fetch("snap-image")
    assert_equal [1], sleep_delays
    assert_equal ["self"], client.requests.fetch(:describe_images).fetch(:owners)
    assert_includes client.requests.fetch(:describe_images).fetch(:filters),
                    { name: "tag:ami_name", values: [ami_name] }
  end

  def test_non_compact_lookup_keeps_exact_name_behavior_without_requiring_a_tag
    ami_name = "runs-on-ubuntu24-full-x64-123"
    client = FakeEc2.new(images: [image(name: ami_name, tag_value: nil)])

    found = BuildResources.find_exact_build_image(
      ec2_client: client,
      ami_name: ami_name,
      require_ami_name_tag: false
    )

    assert_equal "ami-exact", found.image_id
    refute_includes client.requests.fetch(:describe_images).fetch(:filters),
                    { name: "tag:ami_name", values: [ami_name] }
  end

  def test_compact_snapshot_limit_is_explicit_and_strict
    ami_name = "runs-on-ubuntu26-gpu-x64-123"
    ten_gib = 10 * 1024 * 1024 * 1024
    built_image = image(name: ami_name, snapshot_id: "snap-root")
    snapshot = Resource.new(
      snapshot_id: "snap-root",
      full_snapshot_size_in_bytes: ten_gib,
      tags: [tag("ami_name", ami_name)]
    )
    client = FakeEc2.new(images: [built_image], snapshots: [snapshot])
    output = StringIO.new

    result = BuildResources.find_and_validate_build_image!(
      ec2_client: client,
      ami_name: ami_name,
      compact_snapshot_limit_gib: 12,
      output: output,
      sleeper: ->(_delay) {}
    )

    assert_equal built_image, result
    assert_includes output.string, "10.00 GiB"
    assert_includes output.string, "<12 GiB"
  end

  def test_failed_post_build_validation_cleans_the_ami_and_snapshot_before_raising
    ami_name = "runs-on-ubuntu26-full-x64-123"
    eight_gib = 8 * 1024 * 1024 * 1024
    built_image = image(name: ami_name, snapshot_id: "snap-root")
    snapshot = Resource.new(
      snapshot_id: "snap-root",
      full_snapshot_size_in_bytes: eight_gib,
      tags: [tag("ami_name", ami_name)]
    )
    client = FakeEc2.new(images: [built_image], snapshots: [snapshot])

    error = assert_raises(RuntimeError) do
      BuildResources.find_and_validate_build_image!(
        ec2_client: client,
        ami_name: ami_name,
        compact_snapshot_limit_gib: 8,
        output: StringIO.new,
        sleeper: ->(_delay) {}
      )
    end

    assert_includes error.message, "exceeding the required <8 GiB limit"
    assert_includes client.events, [:deregister_image, "ami-exact"]
    assert_includes client.events, [:delete_snapshot, "snap-root"]
  end

  def test_build_script_uses_selected_region_and_has_no_pre_cleanup_raise
    script = File.read(File.expand_path("../bin/build", __dir__))

    refute_includes script, "Aws::EC2::Client.new(region: 'us-east-1')"
    refute_includes script, 'raise("Packer build failed") unless build_succeeded'
    assert_includes script, "BuildResources.cleanup_failed_build"
    assert_includes script, "BuildResources.find_and_validate_build_image!"
  end
end
