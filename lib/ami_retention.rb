require 'time'

module AmiRetention
  PUBLISHED_AT_TAG = 'runs-on:published-at'.freeze
  DAY = 86_400
  PRODUCTION_GRACE = 10 * DAY
  DEV_LIFETIME = 7 * DAY

  module_function

  def published_at(image)
    value = image.tags.find { |tag| tag.key == PUBLISHED_AT_TAG }&.value
    Time.iso8601(value) if value
  end

  # Observe old, untagged releases conservatively. CreationDate is the copy's
  # start time, not evidence that the image was available to customers then.
  def plan(images, production:, now:)
    if !production
      return images.map do |image|
        expired = Time.iso8601(image.creation_date) < now - DEV_LIFETIME
        { image: image, delete: expired, reason: expired ? 'dev image older than 7 days' : 'dev image within 7 days' }
      end
    end

    images.group_by { |image| image.name.split('-')[3..5] }.flat_map do |_family, family_images|
      successor = nil
      family_images.sort_by { |image| [image.creation_date, image.image_id] }.reverse.map do |image|
        published = image.state == 'available' && image.public
        observed_at = published_at(image) if published
        replacement_time = successor && (published_at(successor) || now)
        eligible_at = replacement_time && replacement_time + PRODUCTION_GRACE
        reason = if !successor
          'no newer available public release'
        elsif now < eligible_at
          "replacement grace ends #{eligible_at.utc.iso8601}"
        else
          "replacement public since #{replacement_time.utc.iso8601}"
        end
        row = { image: image, delete: !!(eligible_at && now >= eligible_at), reason: reason,
                observe_publication: published && observed_at.nil?, eligible_at: eligible_at&.utc&.iso8601,
                successor_id: successor&.image_id }
        successor = image if published
        row
      end
    end
  end
end
