require 'minitest/autorun'
require 'stringio'
require 'tmpdir'
load File.expand_path('../bin/utils/cleanup-amis', __dir__)

class AmiCleanupTest < Minitest::Test
  NOW = Time.utc(2026, 9, 28, 12)

  def image(id, days:, production: true, published_days: nil, public: true, state: 'available', family: 'ubuntu24-full-x64')
    { image_id: id, name: "runs-on-#{production ? 'v2.2' : 'dev'}-#{family}-#{id}",
      creation_date: (NOW - days * 86_400).iso8601, state: state, public: public,
      tags: [{ key: 'creator', value: 'RunsOn' }] + (published_days ? [{ key: AmiRetention::PUBLISHED_AT_TAG, value: (NOW - published_days * 86_400).iso8601 }] : []),
      block_device_mappings: [{ device_name: '/dev/sda1', ebs: { snapshot_id: "snap-#{id}" } }] }
  end

  def client(images)
    ec2 = Aws::EC2::Client.new(stub_responses: true, region: 'us-east-1')
    ec2.stub_responses(:describe_images, images: images)
    ec2.stub_responses(:describe_snapshots, snapshots: images.map { |i| { snapshot_id: "snap-#{i[:image_id]}", tags: i[:tags] } })
    ec2
  end

  def plan(images, production: true)
    ec2 = client(images)
    AmiRetention.plan(AmiCleanup.inventory(ec2, production ? 'runs-on-v2.2' : 'runs-on-dev'), production: production, now: NOW)
  end

  def rules
    [{ 'Status' => 'available', 'RetentionPeriod' => { 'RetentionPeriodUnit' => 'DAYS', 'RetentionPeriodValue' => 7 },
       'ResourceTags' => [{ 'ResourceTagKey' => 'creator', 'ResourceTagValue' => 'RunsOn' }] }]
  end

  def test_production_uses_replacement_publication_not_either_creation_date
    rows = plan([image('old', days: 150, published_days: 149), image('new', days: 30, published_days: 9)])
    refute rows.any? { |row| row[:delete] }
    assert_equal 'new', rows.find { |row| row[:image].image_id == 'old' }[:successor_id]
    rows = plan([image('old', days: 150, published_days: 149), image('new', days: 30, published_days: 10)])
    assert_equal ['old'], rows.select { |row| row[:delete] }.map { |row| row[:image].image_id }
  end

  def test_each_predecessor_has_its_own_grace_window
    rows = plan([image('a', days: 30, published_days: 30), image('b', days: 15, published_days: 15), image('c', days: 2, published_days: 2)])
    assert_equal ['a'], rows.select { |row| row[:delete] }.map { |row| row[:image].image_id }
  end

  def test_latest_and_distinct_families_are_kept
    rows = plan([image('a', days: 100, published_days: 100), image('b', days: 90, published_days: 90, family: 'windows25-full-x64')])
    refute rows.any? { |row| row[:delete] }
  end

  def test_pending_private_or_disabled_replacements_do_not_start_grace
    [{ state: 'pending' }, { public: false }, { state: 'disabled' }].each do |attrs|
      rows = plan([image('old', days: 30, published_days: 30), image('new', days: 20, published_days: 20, **attrs)])
      refute rows.any? { |row| row[:delete] }
    end
  end

  def test_untagged_public_replacement_starts_from_observation_not_creation
    rows = plan([image('old', days: 100), image('new', days: 50)])
    refute rows.any? { |row| row[:delete] }
    assert rows.all? { |row| row[:observe_publication] }
    assert_equal (NOW + 10 * 86_400).iso8601, rows.last[:eligible_at]
  end

  def test_dev_expires_all_versions_including_latest_strictly_after_seven_days
    rows = plan([image('old', days: 8, production: false), image('boundary', days: 7, production: false), image('new', days: 1, production: false)], production: false)
    assert_equal ['old'], rows.select { |row| row[:delete] }.map { |row| row[:image].image_id }
    assert plan([image('only', days: 8, production: false)], production: false).first[:delete]
  end

  def test_inventory_scopes_owner_and_follows_all_pages
    ec2 = client([])
    ec2.stub_responses(:describe_images, [{ images: [image('old', days: 30)], next_token: 'next' }, { images: [image('new', days: 1)] }])
    assert_equal %w[old new], AmiCleanup.inventory(ec2, 'runs-on-v2.2').map(&:image_id)
    requests = ec2.api_requests
    assert_equal ['self'], requests.first[:params][:owners]
    assert requests.first[:params][:include_disabled]
    assert requests.first[:params][:include_deprecated]
    assert_equal 'next', requests.last[:params][:next_token]
  end

  def test_dry_run_dev_checks_oregon_without_writing_anything
    ec2 = client([image('old', days: 8, production: false)])
    regions = []
    Dir.mktmpdir do |dir|
      output = File.join(dir, 'plan.json')
      assert AmiCleanup.run(['--region', 'us-west-2', '--dry-run', '--force', '--json', output], out: StringIO.new, now: NOW,
                            client_factory: ->(region) { regions << region; ec2 }, rule_loader: ->(*) { [] })
      result = JSON.parse(File.read(output))
      assert_equal 1, result['delete_count']
      refute_empty result['protection_errors']
    end
    assert_equal ['us-west-2'], regions
    assert ec2.api_requests.all? { |request| request[:operation_name].to_s.start_with?('describe_') }
  end

  def test_production_dry_run_does_not_record_observation_tags
    ec2 = client([image('old', days: 100), image('new', days: 50)])
    assert AmiCleanup.run(['--prod', '--dry-run', '--region', 'us-east-1'], out: StringIO.new, now: NOW, client_factory: ->(_) { ec2 })
    assert_equal [:describe_images], ec2.api_requests.map { |request| request[:operation_name] }
  end

  def test_missing_snapshot_protection_blocks_the_whole_apply
    ec2 = client([image('old', days: 8, production: false)])
    refute AmiCleanup.run(['--force', '--region', 'us-east-1'], out: StringIO.new, now: NOW,
                          client_factory: ->(_) { ec2 }, rule_loader: ->(_, type) { type == 'EC2_IMAGE' ? rules : [] })
    assert ec2.api_requests.all? { |request| request[:operation_name].to_s.start_with?('describe_') }
  end

  def test_apply_deletes_associated_snapshots_and_rejects_partial_failure
    ec2 = client([image('old', days: 8, production: false)])
    rows = AmiRetention.plan(AmiCleanup.inventory(ec2, 'runs-on-dev'), production: false, now: NOW)
    ec2.stub_responses(:deregister_image, return: true, delete_snapshot_results: [{ snapshot_id: 'snap-old', return_code: 'client-error' }])
    assert_raises(RuntimeError) { AmiCleanup.apply(ec2, rows, now: NOW) }
    assert ec2.api_requests.last[:params][:delete_associated_snapshots]
    ec2.stub_responses(:deregister_image, return: true, delete_snapshot_results: [{ snapshot_id: 'snap-old', return_code: 'success' }])
    AmiCleanup.apply(ec2, rows, now: NOW)
  end

  def test_apply_records_first_observation
    ec2 = client([image('new', days: 50)])
    rows = AmiRetention.plan(AmiCleanup.inventory(ec2, 'runs-on-v2.2'), production: true, now: NOW)
    AmiCleanup.apply(ec2, rows, now: NOW)
    assert_equal [{ key: AmiRetention::PUBLISHED_AT_TAG, value: NOW.iso8601 }], ec2.api_requests.last[:params][:tags]
  end

  def test_recycle_bin_matching_requires_available_rules_and_matching_tags
    tags = [Aws::EC2::Types::Tag.new(key: 'creator', value: 'RunsOn')]
    assert AmiRecycleBin.protected?(rules, tags)
    refute AmiRecycleBin.protected?(rules, [])
    refute AmiRecycleBin.protected?([rules.first.merge('Status' => 'pending')], tags)
    excluded = rules.first.merge('ResourceTags' => [], 'ExcludeResourceTags' => rules.first['ResourceTags'])
    refute AmiRecycleBin.protected?([excluded], tags)
    assert AmiRecycleBin.protected?([rules.first.merge('ResourceTags' => [])], [])
  end
end
