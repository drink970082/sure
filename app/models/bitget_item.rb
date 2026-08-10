# frozen_string_literal: true

class BitgetItem < ApplicationRecord
  include Syncable, Provided, Unlinking, Encryptable

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  if encryption_ready?
    encrypts :api_key, deterministic: true
    encrypts :api_secret
    encrypts :passphrase
    encrypts :raw_payload
  end

  validates :name, presence: true
  validates :api_key, presence: true
  validates :api_secret, presence: true
  validates :passphrase, presence: true

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :bitget_accounts, dependent: :destroy
  has_many :accounts, through: :bitget_accounts

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :syncable, -> { active }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  scope :credentials_configured, -> {
    where.not(api_key: [ nil, "" ]).where.not(api_secret: nil).where.not(passphrase: nil)
  }

  before_validation :strip_credentials

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end

  def import_latest_bitget_data
    provider = bitget_provider
    raise StandardError, "Bitget credentials not configured" unless provider

    BitgetItem::Importer.new(self, bitget_provider: provider).import
  rescue StandardError => e
    Rails.logger.error "BitgetItem #{id} - Failed to import: #{e.full_message}"
    raise
  end

  def process_accounts
    return [] if bitget_accounts.empty?

    results = []
    bitget_accounts.joins(:account).merge(Account.visible).each do |bitget_account|
      begin
        result = BitgetAccount::Processor.new(bitget_account).process
        results << { bitget_account_id: bitget_account.id, success: true, result: result }
      rescue StandardError => e
        Rails.logger.error "BitgetItem #{id} - Failed to process account #{bitget_account.id}: #{e.full_message}"
        results << { bitget_account_id: bitget_account.id, success: false, error: e.message }
      end
    end

    results
  end

  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    accounts.visible.map do |account|
      account.sync_later(
        parent_sync: parent_sync,
        window_start_date: window_start_date,
        window_end_date: window_end_date
      )
      { account_id: account.id, success: true }
    rescue StandardError => e
      Rails.logger.error "BitgetItem #{id} - Failed to schedule sync for account #{account.id}: #{e.full_message}"
      { account_id: account.id, success: false, error: e.message }
    end
  end

  def upsert_bitget_snapshot!(payload)
    update!(raw_payload: payload)
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  def sync_status_summary
    total = total_accounts_count
    linked = linked_accounts_count
    unlinked = unlinked_accounts_count

    if total.zero?
      I18n.t("bitget_items.bitget_item.sync_status.no_accounts")
    elsif unlinked.zero?
      I18n.t("bitget_items.bitget_item.sync_status.all_synced", count: linked)
    else
      I18n.t("bitget_items.bitget_item.sync_status.partial_sync", linked_count: linked, unlinked_count: unlinked)
    end
  end

  def linked_accounts_count
    bitget_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    bitget_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    bitget_accounts.count
  end

  def stale_rate_accounts
    bitget_accounts
      .joins(:account)
      .where(accounts: { status: "active" })
      .where("bitget_accounts.extra -> 'bitget' ->> 'stale_rate' = 'true'")
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def credentials_configured?
    api_key.to_s.strip.present? && api_secret.to_s.strip.present? && passphrase.to_s.strip.present?
  end

  def set_bitget_institution_defaults!
    update!(
      institution_name: "Bitget",
      institution_domain: "bitget.com",
      institution_url: "https://www.bitget.com",
      institution_color: "#00F0FF"
    )
  end

  private

    def strip_credentials
      self.api_key = api_key.to_s.strip if api_key_changed? && !api_key.nil?
      self.api_secret = api_secret.to_s.strip if api_secret_changed? && !api_secret.nil?
      self.passphrase = passphrase.to_s.strip if passphrase_changed? && !passphrase.nil?
    end
end
