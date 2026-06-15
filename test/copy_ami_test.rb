require "minitest/autorun"
require "json"
require "stringio"
require "tmpdir"
require "timeout"
load File.expand_path("../bin/copy-ami", __dir__)

FakeEbs = Struct.new(:snapshot_id)
FakeBlockDeviceMapping = Struct.new(:ebs)
FakeImage = Struct.new(:image_id, :name, :state, :public, :creation_date, :block_device_mappings)
FakeDescribeImagesResponse = Struct.new(:images)
FakeCopyImageResponse = Struct.new(:image_id)

class FakeEc2Client
  attr_reader :copied_names, :published_images, :published_snapshots

  def initialize(images_by_name: {}, images_by_id: {}, wait_errors: {}, copy_image_id: nil, on_wait: nil)
    @images_by_name = images_by_name
    @images_by_id = images_by_id
    @wait_errors = wait_errors
    @copy_image_id = copy_image_id
    @on_wait = on_wait
    @copied_names = []
    @published_images = []
    @published_snapshots = []
  end

  def describe_images(owners: nil, filters: nil, image_ids: nil)
    if image_ids
      images = image_ids.filter_map { |image_id| @images_by_id[image_id] }
      return FakeDescribeImagesResponse.new(images)
    end

    name_filter = filters.find { |filter| filter[:name] == "name" }
    image_name = name_filter[:values].first
    image = @images_by_name[image_name]
    FakeDescribeImagesResponse.new(image ? [image] : [])
  end

  def copy_image(source_region:, source_image_id:, copy_image_tags:, name:, description:)
    @copied_names << name
    FakeCopyImageResponse.new(@copy_image_id)
  end

  def wait_until(waiter_name, params)
    @on_wait&.call(waiter_name, params)

    error = @wait_errors[waiter_name]
    raise error if error

    image_id = params[:image_ids]&.first
    if waiter_name == :image_available && image_id && @images_by_id[image_id]
      @images_by_id[image_id].state = "available"
    end
  end

  def modify_snapshot_attribute(snapshot_id:, attribute:, operation_type:, group_names:)
    @published_snapshots << snapshot_id
  end

  def modify_image_attribute(image_id:, launch_permission:)
    @published_images << image_id
    @images_by_id[image_id].public = true if @images_by_id[image_id]
  end
end

class CopyAmiTest < Minitest::Test
  def test_existing_public_ami_is_treated_as_success
    image = build_image(image_id: "ami-public", name: "runs-on-v2.2-windows25-full-x64-123", state: "available", public: true)
    client = FakeEc2Client.new(images_by_name: { image.name => image }, images_by_id: { image.image_id => image })
    out = StringIO.new

    result = CopyAmi.process_region(
      source_ami_id: "ami-source",
      target_name: image.name,
      region: "us-east-1",
      wait_options: CopyAmi::WINDOWS_WAIT_OPTIONS,
      ec2: client,
      out: out
    )

    assert_equal "already public", result[:status]
    assert_equal true, result[:success]
    assert_empty client.published_images
    assert_empty client.published_snapshots
  end

  def test_existing_private_ami_is_reused_and_published
    image = build_image(image_id: "ami-private", name: "runs-on-v2.2-windows25-full-x64-123", state: "available", public: false)
    client = FakeEc2Client.new(images_by_name: { image.name => image }, images_by_id: { image.image_id => image })
    out = StringIO.new

    result = CopyAmi.process_region(
      source_ami_id: "ami-source",
      target_name: image.name,
      region: "us-east-2",
      wait_options: CopyAmi::WINDOWS_WAIT_OPTIONS,
      ec2: client,
      out: out
    )

    assert_equal "published", result[:status]
    assert_equal true, result[:success]
    assert_equal ["ami-private"], client.published_images
    assert_equal ["snap-ami-private"], client.published_snapshots
  end

  def test_missing_ami_triggers_copy
    copied = build_image(image_id: "ami-copied", name: "runs-on-v2.2-ubuntu22-full-x64-123", state: "pending", public: false)
    client = FakeEc2Client.new(images_by_name: {}, images_by_id: { copied.image_id => copied }, copy_image_id: copied.image_id)
    out = StringIO.new

    result = CopyAmi.process_region(
      source_ami_id: "ami-source",
      target_name: copied.name,
      region: "eu-west-1",
      wait_options: CopyAmi::DEFAULT_WAIT_OPTIONS,
      ec2: client,
      out: out
    )

    assert_equal [copied.name], client.copied_names
    assert_equal "published", result[:status]
    assert_equal true, result[:success]
  end

  def test_timeout_does_not_stop_later_regions_and_run_returns_false
    source_image = build_image(image_id: "ami-source", name: "runs-on-dev-windows25-full-x64-123", state: "available", public: false)
    first_region_image = build_image(image_id: "ami-timeout", name: "runs-on-v2.2-windows25-full-x64-123", state: "pending", public: false)
    second_region_image = build_image(image_id: "ami-published", name: "runs-on-v2.2-windows25-full-x64-123", state: "available", public: false)

    source_client = FakeEc2Client.new(images_by_name: { source_image.name => source_image }, images_by_id: { source_image.image_id => source_image })
    timeout_client = FakeEc2Client.new(
      images_by_name: { first_region_image.name => first_region_image },
      images_by_id: { first_region_image.image_id => first_region_image },
      wait_errors: { image_available: Aws::Waiters::Errors::TooManyAttemptsError.new(1) }
    )
    success_client = FakeEc2Client.new(images_by_name: { second_region_image.name => second_region_image }, images_by_id: { second_region_image.image_id => second_region_image })
    out = StringIO.new

    results = CopyAmi.copy_ami_to_regions(
      source_image.name,
      %w[us-east-2 us-west-2],
      true,
      source_client: source_client,
      client_factory: lambda { |region|
        region == "us-east-2" ? timeout_client : success_client
      },
      out: out
    )

    assert_equal ["timed out", "published"], results.map { |result| result[:status] }
    assert_equal [false, true], results.map { |result| result[:success] }
    assert_includes out.string, "Region summary:"
  end

  def test_summary_json_contains_image_name_image_id_and_region_ami_ids
    source_image = build_image(image_id: "ami-source", name: "runs-on-dev-ubuntu24-full-x64-123", state: "available", public: false)
    first_region_image = build_image(image_id: "ami-us-east-1", name: "runs-on-v2.2-ubuntu24-full-x64-123", state: "available", public: false)
    second_region_image = build_image(image_id: "ami-eu-west-1", name: "runs-on-v2.2-ubuntu24-full-x64-123", state: "available", public: false)

    source_client = FakeEc2Client.new(images_by_name: { source_image.name => source_image }, images_by_id: { source_image.image_id => source_image })
    first_region_client = FakeEc2Client.new(images_by_name: { first_region_image.name => first_region_image }, images_by_id: { first_region_image.image_id => first_region_image })
    second_region_client = FakeEc2Client.new(images_by_name: { second_region_image.name => second_region_image }, images_by_id: { second_region_image.image_id => second_region_image })
    out = StringIO.new

    Dir.mktmpdir do |dir|
      summary_path = File.join(dir, "summary.json")
      CopyAmi.copy_ami_to_regions(
        source_image.name,
        %w[us-east-1 eu-west-1],
        true,
        source_client: source_client,
        client_factory: lambda { |region|
          region == "us-east-1" ? first_region_client : second_region_client
        },
        summary_json: summary_path,
        out: out
      )

      summary = JSON.parse(File.read(summary_path))
      assert_equal "ubuntu24-full-x64", summary.fetch("image_id")
      assert_equal "runs-on-v2.2-ubuntu24-full-x64-123", summary.fetch("ami_name")
      assert_equal(
        [
          ["us-east-1", "ami-us-east-1"],
          ["eu-west-1", "ami-eu-west-1"]
        ],
        summary.fetch("regions").map { |region| [region.fetch("region"), region.fetch("ami_id")] }
      )
      refute_includes summary.keys, "source_region"
      refute_includes summary.keys, "source_ami_id"
      refute_includes summary.fetch("regions").first.keys, "snapshot_id"
      refute_includes summary.fetch("regions").first.keys, "status"
    end
  end

  def test_regions_are_processed_in_parallel_and_results_keep_input_order
    started_regions = Queue.new
    release_first_region = Queue.new
    out = StringIO.new

    copy_thread = Thread.new do
      CopyAmi.process_regions(
        source_ami_id: "ami-source",
        target_name: "runs-on-v2.2-ubuntu24-full-x64-123",
        regions: %w[us-east-1 eu-west-1],
        wait_options: CopyAmi::DEFAULT_WAIT_OPTIONS,
        client_factory: lambda { |region|
          image = build_image(image_id: "ami-#{region}", name: "runs-on-v2.2-ubuntu24-full-x64-123", state: "available", public: false)
          FakeEc2Client.new(
            images_by_name: { image.name => image },
            images_by_id: { image.image_id => image },
            on_wait: lambda { |waiter_name, _params|
              next unless waiter_name == :image_available

              started_regions << region
              release_first_region.pop if region == "us-east-1"
            }
          )
        },
        out: out
      )
    end

    first_started = Timeout.timeout(1) { started_regions.pop }
    second_started = Timeout.timeout(1) { started_regions.pop }

    assert_equal %w[eu-west-1 us-east-1], [first_started, second_started].sort

    release_first_region << true
    results = Timeout.timeout(5) { copy_thread.value }

    assert_equal %w[us-east-1 eu-west-1], results.map { |result| result.fetch(:region) }
    assert_equal [true, true], results.map { |result| result.fetch(:success) }
  ensure
    release_first_region << true if defined?(release_first_region)
    copy_thread&.kill if defined?(copy_thread) && copy_thread&.alive?
  end

  private

  def build_image(image_id:, name:, state:, public:)
    FakeImage.new(
      image_id,
      name,
      state,
      public,
      "2026-03-13T07:38:00.000Z",
      [FakeBlockDeviceMapping.new(FakeEbs.new("snap-#{image_id}"))]
    )
  end
end
