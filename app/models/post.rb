require 'html/sanitizer'

class Post < ActiveRecord::Base
  before_validation do
    if body_changed?
      # Render body to HTML
      self.body_html = Formatter.new(body).complete.to_s

      # Update editing timestamp
      self.edited_at = Time.now
    end

    # Extract and save tags
    self.tags = TagExtractor.extract_tags(HTML::FullSanitizer.new.sanitize(body_html)).map(&:downcase)

    # Generate slug
    self.slug ||= generate_slug

    # Set GUID
    self.guid = "#{domain}/#{slug}"

    # Publish post right away... for now
    self.published_at ||= Time.now     # for the SHA

    # Default URL to http://<guid>
    self.url ||= "http://#{guid}"

    # Update SHAs
    self.sha = calculate_sha
  end

  before_update do
    # Remember previous SHA
    if sha_changed? && sha_was.present? && !sha_was.in?(previous_shas)
      self.previous_shas += [sha_was]
    end
  end

  validate(on: :update) do
    if guid_changed?
      errors.add(:guid, "can not be changed.")
    end

    # TODO: check that URL matches GUID
  end

  validates :body,
    presence: true

  validates :sha, :slug, :url,
    presence: true,
    uniqueness: true

  belongs_to :user,
    foreign_key: 'domain',
    primary_key: 'domain'

  has_many :timeline_entries,
    dependent: :destroy

  scope :on_date, ->(date) { where(created_at: (date.at_beginning_of_day)..(date.at_end_of_day)) }
  scope :latest, -> { order('created_at DESC') }
  scope :tagged_with, ->(tag) { where("tags @> ARRAY[?]", tag) }
  scope :referencing, ->(guid) { where("? = ANY(posts.references)", guid) }

  def calculate_sha
    Digest::SHA1.hexdigest("pants:#{guid}:#{referenced_guid}:#{body}")
  end

  def generate_slug
    chars = ('a'..'z').to_a
    numbers = (0..9).to_a

    (Array.new(3) { chars.sample } + Array.new(3) { numbers.sample }).join('')
  end

  def to_param
    slug
  end

  concerning :References do
    included do
      has_many :replies,
        class_name: 'Post',
        foreign_key: 'referenced_guid',
        primary_key: 'guid'

      belongs_to :reference,
        class_name: 'Post',
        foreign_key: 'referenced_guid',
        primary_key: 'guid'
    end

    # Make sure referenced GUID is stored without protocol
    #
    def referenced_guid=(v)
      write_attribute(:referenced_guid, v.present? ? v.strip.without_http : nil)
    end

    # Returns the referenced post IF it's available in the local
    # database.
    #
    def referenced_post
      Post.where(guid: referenced_guid).first if referenced_guid.present?
    end
  end

  class << self
    # The following attributes will be copied from post JSON responses
    # into local Post instances.
    #
    ACCESSIBLE_JSON_ATTRIBUTES = %w{
      guid
      url
      published_at
      edited_at
      referenced_guid
      body
      body_html
      domain
      slug
      sha
      previous_shas
      tags
    }

    def fetch_from(url)
      json = HTTParty.get(url, query: { format: 'json' })

      # Sanity checks
      full, guid, domain, slug = %r{^https?://((.+)/(.+?))(\.json)?$}.match(url).to_a
      if json['guid'] != guid || json['domain'] != domain || json['slug'] != slug
        raise "Post JSON contained corrupted data."
      end

      # Upsert post
      post = where(guid: json['guid']).first_or_initialize
      if post.new_record? || post.edited_at < json['edited_at']
        post.attributes = json.slice(*ACCESSIBLE_JSON_ATTRIBUTES)
        post.save!
      end

      # Upsert the post's author
      author_url = post.url.scan(%r{^https?://.+?/}).first
      User.fetch_from(author_url)

      post
    end
  end
end
