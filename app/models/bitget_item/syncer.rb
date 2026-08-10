# frozen_string_literal: true

class BitgetItem::Syncer
  include SyncStats::Collector

  attr_reader :bitget_item

  def initialize(bitget_item)
    @bitget_item = bitget_item
  end

  def perform_sync(sync)
    sync.update!(status_text: I18n.t("bitget_item.syncer.checking_credentials")) if sync.respond_to?(:status_text)
    unless bitget_item.credentials_configured?
      bitget_item.update!(status: :requires_update)
      mark_failed(sync, I18n.t("bitget_item.syncer.credentials_invalid"))
      return
    end

    sync.update!(status_text: I18n.t("bitget_item.syncer.importing_accounts")) if sync.respond_to?(:status_text)
    bitget_item.import_latest_bitget_data
    bitget_item.update!(status: :good) if bitget_item.requires_update?

    sync.update!(status_text: I18n.t("bitget_item.syncer.checking_configuration")) if sync.respond_to?(:status_text)
    collect_setup_stats(sync, provider_accounts: bitget_item.bitget_accounts.to_a)

    unlinked = bitget_item.bitget_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
    linked = bitget_item.bitget_accounts.joins(:account_provider).joins(:account).merge(Account.visible)

    if unlinked.any?
      bitget_item.update!(pending_account_setup: true)
      sync.update!(status_text: I18n.t("bitget_item.syncer.accounts_need_setup", count: unlinked.count)) if sync.respond_to?(:status_text)
    else
      bitget_item.update!(pending_account_setup: false)
    end

    return unless linked.any?

    sync.update!(status_text: I18n.t("bitget_item.syncer.processing_accounts")) if sync.respond_to?(:status_text)
    bitget_item.process_accounts

    sync.update!(status_text: I18n.t("bitget_item.syncer.calculating_balances")) if sync.respond_to?(:status_text)
    bitget_item.schedule_account_syncs(
      parent_sync: sync,
      window_start_date: sync.window_start_date,
      window_end_date: sync.window_end_date
    )

    account_ids = linked.map { |bitget_account| bitget_account.current_account&.id }.compact
    if account_ids.any?
      collect_transaction_stats(sync, account_ids: account_ids, source: "bitget")
      collect_trades_stats(sync, account_ids: account_ids, source: "bitget")
    end
  rescue Provider::Bitget::AuthenticationError, Provider::Bitget::PermissionError => e
    bitget_item.update!(status: :requires_update)
    mark_failed(sync, e.message)
    raise
  rescue StandardError => e
    Rails.logger.error "BitgetItem::Syncer - unexpected error during sync: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    mark_failed(sync, e.message)
    raise
  end

  def perform_post_sync
  end

  private

    def mark_failed(sync, error_message)
      sync.start! if sync.respond_to?(:may_start?) && sync.may_start?

      if sync.respond_to?(:may_fail?) && sync.may_fail?
        sync.fail!
      elsif sync.respond_to?(:status)
        sync.update!(status: :failed)
      end

      sync.update!(error: error_message) if sync.respond_to?(:error)
      sync.update!(status_text: error_message) if sync.respond_to?(:status_text)
    end
end
