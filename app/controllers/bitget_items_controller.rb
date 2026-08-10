# frozen_string_literal: true

class BitgetItemsController < ApplicationController
  before_action :set_bitget_item, only: %i[update destroy sync setup_accounts complete_account_setup]
  before_action :require_admin!, only: %i[create select_accounts link_accounts select_existing_account link_existing_account update destroy sync setup_accounts complete_account_setup]

  def create
    @bitget_item = Current.family.bitget_items.build(bitget_item_params)
    @bitget_item.name ||= t(".default_name")

    if @bitget_item.save
      @bitget_item.set_bitget_institution_defaults!
      @bitget_item.sync_later
      render_panel_success(t(".success"))
    else
      render_panel_error(@bitget_item.errors.full_messages.join(", "))
    end
  end

  def update
    if @bitget_item.update(bitget_item_params)
      render_panel_success(t(".success"))
    else
      render_panel_error(@bitget_item.errors.full_messages.join(", "))
    end
  end

  def destroy
    @bitget_item.unlink_all!(dry_run: false)
    @bitget_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success")
  end

  def sync
    @bitget_item.sync_later unless @bitget_item.syncing?

    respond_to do |format|
      format.html { redirect_back_or_to settings_providers_path }
      format.json { head :ok }
    end
  end

  def select_accounts
    account_flow = bitget_item_account_flow_context
    bitget_item = account_flow[:bitget_item]

    unless bitget_item
      redirect_to settings_providers_path, alert: bitget_item_selection_message(account_flow[:credentialed_items])
      return
    end

    redirect_to setup_accounts_bitget_item_path(bitget_item, return_to: safe_return_to_path), status: :see_other
  end

  def link_accounts
    bitget_item = bitget_item_account_flow_context[:bitget_item]
    unless bitget_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    redirect_to setup_accounts_bitget_item_path(bitget_item), status: :see_other
  end

  def select_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    account_flow = bitget_item_account_flow_context
    @bitget_item = account_flow[:bitget_item]

    unless manual_crypto_exchange_account?(@account)
      redirect_to accounts_path, alert: t("bitget_items.link_existing_account.errors.only_manual")
      return
    end

    unless @bitget_item
      redirect_to settings_providers_path, alert: bitget_item_selection_message(account_flow[:credentialed_items])
      return
    end

    @available_bitget_accounts = @bitget_item.bitget_accounts
      .left_joins(:account_provider)
      .where(account_providers: { id: nil })
      .order(:name)

    render :select_existing_account, layout: false
  end

  def link_existing_account
    @account = Current.family.accounts.find(params[:account_id])
    bitget_item = bitget_item_account_flow_context[:bitget_item]

    unless manual_crypto_exchange_account?(@account)
      return redirect_or_flash_error(t(".errors.only_manual"), account_path(@account))
    end

    unless bitget_item
      redirect_to settings_providers_path, alert: t(".select_connection")
      return
    end

    bitget_account = bitget_item.bitget_accounts.find_by(id: params[:bitget_account_id])
    unless bitget_account
      return redirect_or_flash_error(t(".errors.invalid_bitget_account"), account_path(@account))
    end
    if bitget_account.account_provider.present?
      return redirect_or_flash_error(t(".errors.bitget_account_already_linked"), account_path(@account))
    end

    AccountProvider.create!(account: @account, provider: bitget_account)
    bitget_item.sync_later

    redirect_to accounts_path, notice: t(".success")
  end

  def setup_accounts
    @bitget_accounts = unlinked_accounts_for(@bitget_item)
  end

  def complete_account_setup
    selected_accounts = Array(params[:selected_accounts]).reject(&:blank?)
    created_accounts = []

    selected_accounts.each do |bitget_account_id|
      bitget_account = @bitget_item.bitget_accounts.find_by(id: bitget_account_id)
      next unless bitget_account

      bitget_account.with_lock do
        next if bitget_account.account_provider.present?

        account = Account.create_from_bitget_account(bitget_account)
        provider_link = bitget_account.ensure_account_provider!(account)
        provider_link ? created_accounts << account : account.destroy!
      end

      BitgetAccount::Processor.new(bitget_account.reload).process
    rescue StandardError => e
      Rails.logger.error("Failed to setup account for BitgetAccount #{bitget_account_id}: #{e.message}")
    end

    @bitget_item.update!(pending_account_setup: unlinked_accounts_for(@bitget_item).exists?)
    @bitget_item.sync_later if created_accounts.any?

    notice = if created_accounts.any?
      t(".success", count: created_accounts.count)
    elsif selected_accounts.empty?
      t(".none_selected")
    else
      t(".no_accounts")
    end

    redirect_to accounts_path, notice: notice, status: :see_other
  end

  private

    def set_bitget_item
      @bitget_item = Current.family.bitget_items.find(params[:id])
    end

    def bitget_item_params
      permitted = params.require(:bitget_item).permit(:name, :sync_start_date, :api_key, :api_secret, :passphrase)
      if @bitget_item&.persisted?
        permitted.delete(:api_key) if permitted[:api_key].blank?
        permitted.delete(:api_secret) if permitted[:api_secret].blank?
        permitted.delete(:passphrase) if permitted[:passphrase].blank?
      end
      permitted
    end

    def render_panel_success(message)
      if turbo_frame_request?
        flash.now[:notice] = message
        @bitget_items = Current.family.bitget_items.active.ordered
        stream = turbo_stream.update("bitget-providers-panel", partial: "settings/providers/bitget_panel", locals: { bitget_items: @bitget_items })
        render turbo_stream: [ stream, *flash_notification_stream_items ]
      else
        redirect_to settings_providers_path, notice: message, status: :see_other
      end
    end

    def render_panel_error(message)
      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "bitget-providers-panel",
          partial: "settings/providers/bitget_panel",
          locals: { error_message: message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: message, status: :see_other
      end
    end

    def bitget_item_account_flow_context
      credentialed_items = Current.family.bitget_items.active.credentials_configured.ordered.select(&:credentials_configured?)
      item = if params[:bitget_item_id].present?
        credentialed_items.find { |candidate| candidate.id.to_s == params[:bitget_item_id].to_s }
      elsif credentialed_items.one?
        credentialed_items.first
      end

      { bitget_item: item, credentialed_items: credentialed_items }
    end

    def unlinked_accounts_for(bitget_item)
      bitget_item.bitget_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).order(:name)
    end

    def bitget_item_selection_message(credentialed_items)
      if credentialed_items.count > 1 && params[:bitget_item_id].blank?
        t("bitget_items.select_accounts.select_connection")
      else
        t("bitget_items.select_accounts.no_credentials_configured")
      end
    end

    def manual_crypto_exchange_account?(account)
      account.manual_crypto_exchange?
    end

    def redirect_or_flash_error(message, fallback_path)
      if turbo_frame_request?
        flash.now[:alert] = message
        render turbo_stream: Array(flash_notification_stream_items)
      else
        redirect_to fallback_path, alert: message
      end
    end

    def safe_return_to_path
      return nil if params[:return_to].blank?

      value = params[:return_to].to_s
      uri = URI.parse(value)
      return nil if uri.scheme.present?
      return nil if uri.host.present?
      return nil unless value.start_with?("/")

      value
    rescue URI::InvalidURIError
      nil
    end
end
