# frozen_string_literal: true

# Turns Bitget financial records (deposits, withdrawals, transfers, rewards,
# funding fees) stored in BitgetAccount#raw_transactions_payload["financial_records"]
# into Transaction entries.
#
# Order fills are handled by BitgetAccount::Processor from /trade/fills, so any
# record whose type mentions ORDER is skipped here to avoid double counting.
#
# Bitget's type enum is open-ended and undocumented in full, so rather than
# allow-listing values this classifies by the sign of `amount` and only skips a
# known-noisy pattern. An unrecognised type still lands as a sensible entry
# instead of being silently dropped.
#
# Sign convention (Sure): negative = inflow/income, positive = outflow/expense.
class BitgetAccount::FinancialRecordProcessor
  include BitgetAccount::UsdConverter

  # Already represented by /trade/fills.
  SKIP_TYPE_PATTERN = /ORDER|TRADE_FILLED/i

  DEPOSIT_TYPE_PATTERN = /DEPOSIT|TRANSFER_IN|RECHARGE/i
  WITHDRAWAL_TYPE_PATTERN = /WITHDRAW|TRANSFER_OUT/i
  FEE_TYPE_PATTERN = /FEE|FUNDING/i

  def initialize(bitget_account)
    @bitget_account = bitget_account
  end

  def process
    return unless account.present?

    # Load existing external IDs once; a 90-day pull can carry a few thousand
    # records and an EXISTS query per record would dominate the sync.
    @existing_external_ids = account.entries
                                    .where(source: "bitget")
                                    .where("external_id LIKE 'bitget_record_%'")
                                    .pluck(:external_id)
                                    .to_set

    raw_records.each do |record_id, record|
      process_record(record_id, record)
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "error",
        message: "Failed to process financial record #{record_id}: #{e.message}",
        source: self.class.name,
        provider_key: "bitget",
        family: bitget_account.bitget_item&.family,
        metadata: { record_id: record_id, error_class: e.class.name }
      )
    end
  end

  private

    attr_reader :bitget_account

    def account
      bitget_account.current_account
    end

    def target_currency
      bitget_account.bitget_item&.family&.currency
    end

    def raw_records
      bitget_account.raw_transactions_payload&.dig("financial_records") || {}
    end

    def process_record(record_id, record)
      type = record["type"].to_s
      return if type.match?(SKIP_TYPE_PATTERN)

      external_id = "bitget_record_#{record_id}"
      return if @existing_external_ids.include?(external_id)

      coin = record["coin"].to_s.upcase
      raw_amount = record["amount"].to_d
      raw_fee = record["fee"].to_d
      date = Time.zone.at(record["ts"].to_d / 1000).to_date

      # Bitget reports fee as a negative number when charged; the balance impact
      # is amount plus that signed fee.
      abs_impact = (raw_amount + raw_fee).abs
      return if abs_impact.zero?

      converted, price_missing = resolve_amount(abs_impact, coin, date)
      return if converted.nil?

      inflow = raw_amount.positive?
      signed_amount = inflow ? -converted.abs : converted.abs

      account.entries.create!(
        date: date,
        name: build_name(type, abs_impact, coin),
        amount: signed_amount,
        currency: target_currency,
        external_id: external_id,
        source: "bitget",
        entryable: Transaction.new(
          kind: transaction_kind(type),
          investment_activity_label: activity_label(type, inflow),
          extra: build_extra(record_id, record, price_missing)
        )
      )

      @existing_external_ids << external_id
    end

    # Returns [family_currency_amount, price_missing_bool] or [nil, nil].
    def resolve_amount(abs_impact, coin, date)
      return [ abs_impact, false ] if coin == target_currency

      if usd_equivalent?(coin)
        converted, stale, = convert_from_usd(abs_impact, date: date)
        return [ converted, stale ]
      end

      return resolve_fiat_amount(abs_impact, coin, date) if BitgetAccount::FIAT_CURRENCIES.include?(coin)

      resolve_crypto_amount(abs_impact, coin, date)
    end

    def usd_equivalent?(coin)
      coin == "USD" || BitgetAccount::STABLECOINS.include?(coin)
    end

    def resolve_fiat_amount(abs_impact, coin, date)
      rate_to_usd = ExchangeRate.find_or_fetch_rate(from: coin, to: "USD", date: date)
      return [ nil, nil ] unless rate_to_usd

      usd_amount = abs_impact * rate_to_usd.rate.to_d
      converted, stale, = convert_from_usd(usd_amount, date: date)
      [ converted, stale ]
    rescue StandardError => e
      capture_warning("Fiat rate fetch failed for #{coin}: #{e.message}", coin: coin, date: date)
      [ nil, nil ]
    end

    def resolve_crypto_amount(abs_impact, coin, date)
      price_usd = stored_price_usd(coin)

      if price_usd.nil?
        capture_warning("No price available for #{coin} on #{date}; amount recorded as 0", coin: coin, date: date)
        return [ 0.to_d, true ]
      end

      converted, stale, = convert_from_usd(abs_impact * price_usd, date: date)
      [ converted, stale ]
    rescue StandardError => e
      capture_warning("Crypto price resolution failed for #{coin}: #{e.message}", coin: coin, date: date)
      [ 0.to_d, true ]
    end

    # Uses the spot price captured by the importer at sync time, not the price
    # on the record's own date - a best-effort approximation, same tradeoff the
    # Kraken ledger processor makes.
    def stored_price_usd(coin)
      assets = bitget_account.raw_payload&.dig("assets") || []
      asset = assets.find { |a| (a["symbol"] || a[:symbol]).to_s.upcase == coin }
      price = asset&.dig("price_usd") || asset&.dig(:price_usd)
      price.present? ? price.to_d : nil
    end

    def build_name(type, abs_impact, coin)
      qty = abs_impact.to_d.round(8).to_s("F").sub(/\.?0+\z/, "")
      "#{type.to_s.tr('_', ' ').downcase.capitalize} #{qty} #{coin}".squish
    end

    def activity_label(type, inflow)
      case type
      when DEPOSIT_TYPE_PATTERN then "Contribution"
      when WITHDRAWAL_TYPE_PATTERN then "Withdrawal"
      when FEE_TYPE_PATTERN then "Fee"
      else inflow ? "Interest" : "Other"
      end
    end

    def transaction_kind(type)
      type.match?(DEPOSIT_TYPE_PATTERN) || type.match?(WITHDRAWAL_TYPE_PATTERN) ? "funds_movement" : "standard"
    end

    def build_extra(record_id, record, price_missing)
      meta = {
        "record_id" => record_id,
        "category" => record["category"],
        "symbol" => record["symbol"],
        "coin" => record["coin"],
        "type" => record["type"],
        "raw_amount" => record["amount"],
        "fee_native" => record["fee"]
      }
      meta["price_missing"] = true if price_missing
      { "bitget" => meta }
    end

    def capture_warning(message, coin:, date:)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "bitget",
        family: bitget_account.bitget_item&.family,
        metadata: { coin: coin, date: date.to_s }
      )
    end
end
