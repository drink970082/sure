class PlaidAccount::Investments::HoldingsProcessor
  IGNORED_HOLDING = Object.new.freeze

  def initialize(plaid_account, security_resolver:)
    @plaid_account = plaid_account
    @security_resolver = security_resolver
  end

  def process
    snapshot = holdings
    return unless snapshot

    attributes = snapshot.map { |plaid_holding| holding_attributes(plaid_holding) }

    importable_attributes = attributes.reject { |item| item.equal?(IGNORED_HOLDING) }

    if account_provider && attributes.all?
      import_adapter.import_holding_snapshot(account_provider: account_provider) do
        importable_attributes.each { |holding_attributes| import_holding(holding_attributes) }
      end
    else
      capture_incomplete_snapshot(snapshot, attributes) if attributes.any?(&:nil?)

      # Preserve partial-import behavior until this provider publishes its first
      # complete snapshot. Recheck under the same lock as snapshot publication.
      account.with_lock do
        if account_provider&.reload&.current_holding_snapshot_id.nil?
          importable_attributes.compact.each { |holding_attributes| import_holding(holding_attributes) }
        end
      end
    end
  end

  private
    attr_reader :plaid_account, :security_resolver

    def holding_attributes(plaid_holding)
      resolved_security_result = security_resolver.resolve(plaid_security_id: plaid_holding["security_id"])
      return IGNORED_HOLDING if resolved_security_result.try(:brokerage_cash?)
      return unless resolved_security_result.security.present?

      quantity = parse_decimal(plaid_holding["quantity"])
      price = parse_decimal(plaid_holding["institution_price"])
      return if quantity.nil? || price.nil?

      {
        security: resolved_security_result.security,
        quantity: quantity,
        amount: quantity * price,
        currency: plaid_holding["iso_currency_code"] || account.currency,
        date: parse_date(plaid_holding["institution_price_as_of"]) || Date.current,
        price: price
      }
    end

    def capture_incomplete_snapshot(snapshot, attributes)
      rejected_security_ids = snapshot.zip(attributes).filter_map do |holding, attributes|
        holding["security_id"] if attributes.nil?
      end

      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Incomplete Plaid holdings response; current snapshot was not advanced",
        source: self.class.name,
        provider_key: "plaid",
        family: account.family,
        account_provider: account_provider,
        metadata: { rejected_security_ids: rejected_security_ids, holdings_count: snapshot.size }
      )
    end

    def import_holding(attributes)
      import_adapter.import_holding(
        **attributes,
        account_provider_id: account_provider&.id,
        source: "plaid",
        delete_future_holdings: false # Plaid doesn't allow holdings deletion
      )
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def account
      plaid_account.current_account
    end

    def account_provider
      plaid_account.account_provider
    end

    def holdings
      payload = plaid_account.raw_holdings_payload
      return unless payload.is_a?(Hash) && payload["holdings"].is_a?(Array)

      payload["holdings"]
    end

    def parse_decimal(value)
      return nil if value.nil?

      case value
      when BigDecimal
        value
      when String
        BigDecimal(value)
      when Numeric
        BigDecimal(value.to_s)
      else
        nil
      end
    rescue ArgumentError => e
      Rails.logger.error("Failed to parse Plaid holding decimal value: #{value.inspect} - #{e.message}")
      nil
    end

    def parse_date(date_value)
      return nil if date_value.nil?

      case date_value
      when Date
        date_value
      when String
        Date.parse(date_value)
      when Time, DateTime
        date_value.to_date
      else
        nil
      end
    rescue ArgumentError, TypeError => e
      Rails.logger.error("Failed to parse Plaid holding date: #{date_value.inspect} - #{e.message}")
      nil
    end
end
