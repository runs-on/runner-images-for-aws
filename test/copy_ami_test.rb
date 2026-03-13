require "minitest/autorun"
require "stringio"
load File.expand_path("../bin/copy-ami", __dir__)

FakeEbs = Struct.new(:snapshot_id)
FakeBlockDeviceMapping = Struct.new(:ebs)
FakeImage = Struct.new(:image_id, :name, :state, :public, :creation_date, :block_device_mappings)
FakeDescribeImagesResponse = Struct.new(:images)
FakeCopyImageResponse = Struct.new(:image_id)

class FakeEc2Client
  attr_reader :copied_names, :published_images, :published_snapshots

  def initialize(images_by_name: {}, images_by_id: {}, wait_errors: {}, copy_image_id: nil)
    @images_by_name = images_by_name
    @images_by_id = images_by_id
    @wait_errors = wait_errors
    @copy_image_id = copy_image_id
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
