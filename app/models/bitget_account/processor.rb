# frozen_string_literal: true

class BitgetAccount::Processor
  include BitgetAccount::UsdConverter

  # Longest first so BTCFDUSD does not get split on a shorter suffix.
  QUOTE_SYMBOLS = %w[FDUSD USDT USDC TUSD DAI USD EUR GBP TRY BRL BTC ETH BGB].freeze

  attr_reader :bitget_account

  def initialize(bitget_account)
    @bitget_account = bitget_account
  end

  def process
    return unless bitget_account.current_account.present?

    BitgetAccount::HoldingsProcessor.new(bitget_account).process
    process_account!
    process_fills
    BitgetAccount::FinancialRecordProcessor.new(bitget_account).process
  end

  private

    def target_currency
      bitget_account.bitget_item&.family&.currency
    end

    def process_account!
      account = bitget_account.current_account
      amount, stale, rate_date = convert_from_usd((bitget_account.current_balance || 0).to_d, date: Date.current)

      account.update!(
        balance: amount,
        cash_balance: 0,
        currency: target_currency
      )

      bitget_account.update!(extra: bitget_account.extra.to_h.deep_merge(build_stale_extra(stale, rate_date, Date.current)))
    end

    def process_fills
      raw_fills.each do |exec_id, fill|
        process_fill(exec_id, fill)
      end
    rescue StandardError => e
      Rails.logger.error "BitgetAccount::Processor - fill processing failed: #{e.message}"
    end

    def raw_fills
      bitget_account.raw_transactions_payload&.dig("fills") || {}
    end

    def process_fill(exec_id, fill)
      account = bitget_account.current_account
      return unless account

      external_id = "bitget_fill_#{exec_id}"
      return if account.entries.exists?(external_id: external_id, source: "bitget")

      side = fill["side"].to_s.downcase
      return unless %w[buy sell].include?(side)

      base_symbol, quote_symbol = split_symbol(fill["symbol"].to_s)
      return if base_symbol.blank?

      qty = fill["execQty"].to_d
      return if qty.zero?

      price = fill["execPrice"].to_d
      cost = fill["execValue"].presence&.to_d || (qty * price).round(8)
      currency = entry_currency_for(quote_symbol)
      fee = fee_for(fill, quote_symbol)
      date = Time.zone.at(fill["createdTime"].to_d / 1000).to_date

      security = BitgetAccount::SecurityResolver.resolve("CRYPTO:#{base_symbol}", base_symbol)
      return unless security

      entry_amount = side == "buy" ? -cost : cost
      trade_qty = side == "buy" ? qty : -qty
      label = side == "buy" ? "Buy" : "Sell"

      account.entries.create!(
        date: date,
        name: "#{label} #{qty.round(8)} #{base_symbol}",
        amount: entry_amount,
        currency: currency,
        external_id: external_id,
        source: "bitget",
        notes: fill["orderId"].presence,
        entryable: Trade.new(
          security: security,
          qty: trade_qty,
          price: price,
          currency: currency,
          fee: fee,
          investment_activity_label: label
        )
      )
    rescue StandardError => e
      Rails.logger.error "BitgetAccount::Processor - failed to process fill #{exec_id}: #{e.message}"
    end

    # Bitget SPOT symbols are BASE and QUOTE concatenated with no separator
    # (BTCUSDT), so the quote has to be recovered by suffix match.
    def split_symbol(symbol)
      upcased = symbol.upcase
      QUOTE_SYMBOLS.each do |quote|
        next unless upcased.end_with?(quote)

        base = upcased.delete_suffix(quote)
        next if base.empty?

        return [ base, quote ]
      end

      [ upcased, "USDT" ]
    end

    # USDT and friends are not ISO currencies, so Money cannot price them.
    # Treating them as USD 1:1 matches how the holdings side already values the
    # account (Bitget's own usdValue) and keeps entries in a currency Sure
    # understands. The raw quote stays visible in the fill payload.
    def entry_currency_for(quote_symbol)
      return "USD" if quote_symbol.blank?
      return "USD" if BitgetAccount::STABLECOINS.include?(quote_symbol)

      Money::Currency.new(quote_symbol)
      quote_symbol
    rescue Money::Currency::UnknownCurrencyError
      "USD"
    end

    # feeDetail is a list because a fill can be charged in more than one coin
    # (for example BGB discounts). Only fees denominated in the quote coin are
    # comparable to the entry amount; anything else would be a different unit.
    # ponytail: non-quote fee coins are dropped rather than converted. Convert
    # via the asset price table if fee accuracy ever matters.
    def fee_for(fill, quote_symbol)
      Array(fill["feeDetail"]).sum do |detail|
        next 0.to_d unless detail["feeCoin"].to_s.upcase == quote_symbol.to_s.upcase

        detail["fee"].to_d.abs
      end
    end
end
