# frozen_string_literal: true

class BitgetItem::Importer
  # Guards every cursor loop in here against a server that keeps handing back a
  # cursor. At 100 rows a page this ceiling is never reached in practice.
  MAX_PAGES = 100

  # Bitget's UTA endpoints are per product type; SPOT is the only one this
  # importer models. Futures/margin positions are not imported.
  # ponytail: SPOT only. Add "USDT-FUTURES" here plus position handling in the
  # processor if derivatives ever need to show up.
  CATEGORY = "SPOT"

  attr_reader :bitget_item, :bitget_provider

  def initialize(bitget_item, bitget_provider:)
    @bitget_item = bitget_item
    @bitget_provider = bitget_provider
  end

  def import
    account_data = bitget_provider.get_account_assets || {}

    # Three separate pots, none of which shows the others: the unified trading
    # account, the funding account, and Earn. Only the first reports a USD
    # value, so the other two are priced from the public ticker table.
    trading_assets = parse_trading_assets(account_data)
    funding_assets = parse_funding_assets(fetch_funding_assets)
    earn_assets = parse_earn_assets(fetch_savings_assets)
    assets = trading_assets + funding_assets + earn_assets

    fills = fetch_fills
    financial_records = fetch_financial_records

    total_usd = total_usd_for(account_data, trading_assets, funding_assets + earn_assets)

    bitget_account = upsert_bitget_account(
      assets: assets,
      account_data: account_data,
      fills: fills,
      financial_records: financial_records,
      total_usd: total_usd
    )

    bitget_item.upsert_bitget_snapshot!({
      "account" => account_data.except("assets"),
      "imported_at" => Time.current.iso8601
    })

    {
      success: true,
      account_id: bitget_account.id,
      assets_imported: assets.size,
      assets_by_source: assets.group_by { |asset| asset[:source] }.transform_values(&:size),
      fills_imported: fills.size,
      financial_records_imported: financial_records.size,
      total_usd: total_usd
    }
  rescue Provider::Bitget::PermissionError => e
    bitget_item.update!(status: :requires_update)
    raise e
  end

  private

    # The trading account is the one place Bitget reports a per-coin USD
    # valuation, so unlike the other two pots it needs no ticker lookup.
    def parse_trading_assets(account_data)
      Array(account_data["assets"]).filter_map do |asset|
        symbol = asset["coin"].to_s.upcase
        next if symbol.blank?

        balance = asset["equity"].presence&.to_d || asset["balance"].to_d
        locked = asset["locked"].to_d
        next if balance.zero? && locked.zero?

        usd_value = asset["usdValue"].presence&.to_d
        price_usd = (usd_value / balance if usd_value && !balance.zero?)

        {
          symbol: symbol,
          price_symbol: symbol,
          balance: balance.to_s("F"),
          available: asset["available"].to_d.to_s("F"),
          locked: locked.to_s("F"),
          debt: asset["debt"].to_d.to_s("F"),
          price_usd: price_usd&.to_s("F"),
          amount_usd: (usd_value || 0.to_d).to_s("F"),
          price_status: price_usd ? "exact" : "missing",
          source: "spot"
        }
      end
    end

    def parse_funding_assets(rows)
      Array(rows).filter_map do |asset|
        symbol = asset["coin"].to_s.upcase
        next if symbol.blank?

        balance = asset["balance"].presence&.to_d || asset["available"].to_d
        next if balance.zero?

        build_priced_asset(
          symbol: symbol,
          balance: balance,
          available: asset["available"].to_d,
          locked: asset["frozen"].to_d,
          source: "funding"
        )
      end
    end

    # Earn reports holdAmount (principal) and totalProfit (accrued but not yet
    # credited) separately. Only the principal is counted: accrued interest
    # lands in a real balance when it is paid out, and counting it here as well
    # would show it twice.
    def parse_earn_assets(rows)
      Array(rows).filter_map do |asset|
        symbol = asset["productCoin"].to_s.upcase
        next if symbol.blank?

        balance = asset["holdAmount"].to_d
        next if balance.zero?

        build_priced_asset(
          symbol: symbol,
          balance: balance,
          available: 0.to_d,
          locked: balance,
          source: "earn_#{asset['periodType'].presence || 'flexible'}"
        )
      end
    end

    def build_priced_asset(symbol:, balance:, available:, locked:, source:)
      price_usd = usd_price_for(symbol)
      amount_usd = price_usd ? (balance * price_usd) : 0.to_d

      {
        symbol: symbol,
        price_symbol: symbol,
        balance: balance.to_s("F"),
        available: available.to_s("F"),
        locked: locked.to_s("F"),
        debt: "0.0",
        price_usd: price_usd&.to_s("F"),
        amount_usd: amount_usd.to_s("F"),
        price_status: price_usd ? "exact" : "missing",
        source: source
      }
    end

    def usd_price_for(symbol)
      return 1.to_d if symbol == "USD" || BitgetAccount::STABLECOINS.include?(symbol)

      ticker_prices[symbol]
    end

    # Fetched lazily and once: only needed when the funding account or Earn
    # actually hold something, and it is a single unauthenticated call.
    def ticker_prices
      @ticker_prices ||= begin
        Array(bitget_provider.get_spot_tickers).each_with_object({}) do |ticker, table|
          symbol = ticker["symbol"].to_s.upcase
          next unless symbol.end_with?("USDT")

          price = ticker["lastPr"].presence&.to_d
          next if price.nil? || price.zero?

          table[symbol.delete_suffix("USDT")] = price
        end
      rescue StandardError => e
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "Could not load Bitget spot tickers; funding and Earn balances will be unpriced: #{e.message}",
          source: self.class.name,
          provider_key: "bitget",
          family: bitget_item.family,
          metadata: { bitget_item_id: bitget_item.id, error_class: e.class.name }
        )
        {}
      end
    end

    def fetch_funding_assets
      bitget_provider.get_funding_assets
    rescue Provider::Bitget::PermissionError => e
      degrade("funding account", e)
      []
    end

    # Earn has no combined view, so flexible and fixed are pulled separately and
    # concatenated. A key without Earn read permission degrades to empty rather
    # than failing the whole sync.
    def fetch_savings_assets
      Provider::Bitget::SAVINGS_PERIOD_TYPES.flat_map do |period_type|
        cursor = nil
        rows = []

        MAX_PAGES.times do
          data = bitget_provider.get_savings_assets(period_type: period_type, id_less_than: cursor) || {}
          page = Array(data["resultList"])
          rows.concat(page)

          cursor = data["endId"].presence
          break if cursor.nil? || page.empty?
        end

        rows
      end
    rescue Provider::Bitget::PermissionError => e
      degrade("Earn savings", e)
      []
    end

    def degrade(what, error)
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "#{what} not permitted for this key; skipping: #{error.message}",
        source: self.class.name,
        provider_key: "bitget",
        family: bitget_item.family,
        metadata: { bitget_item_id: bitget_item.id }
      )
    end

    # accountEquity is Bitget's own USD valuation, but it covers the trading
    # account only - the other two pots have to be added on top.
    def total_usd_for(account_data, trading_assets, other_assets)
      equity = account_data["accountEquity"].presence&.to_d
      equity ||= trading_assets.sum { |asset| asset[:amount_usd].to_d }

      (equity + other_assets.sum { |asset| asset[:amount_usd].to_d }).round(2)
    end

    def fetch_fills
      paginate_windows do |start_ms, end_ms, cursor|
        bitget_provider.get_fills(
          category: CATEGORY, start_time: start_ms, end_time: end_ms, cursor: cursor
        )
      end.index_by { |fill| fill["execId"].to_s }
    end

    def fetch_financial_records
      paginate_windows do |start_ms, end_ms, cursor|
        bitget_provider.get_financial_records(
          category: CATEGORY, start_time: start_ms, end_time: end_ms, cursor: cursor
        )
      end.index_by { |record| record["id"].to_s }
    rescue Provider::Bitget::PermissionError => e
      # The key may lack the permission this endpoint needs; holdings and fills
      # are still worth keeping, so degrade instead of failing the whole sync.
      DebugLogEntry.capture(
        category: "provider_sync_error",
        level: "warn",
        message: "Financial records permission denied; skipping: #{e.message}",
        source: self.class.name,
        provider_key: "bitget",
        family: bitget_item.family,
        metadata: { bitget_item_id: bitget_item.id }
      )
      {}
    end

    # Bitget caps history at 90 days and a single query at a 30-day span, so a
    # full pull is a handful of windows, each cursor-paginated to exhaustion.
    def paginate_windows
      rows = []

      history_windows.each do |start_ms, end_ms|
        cursor = nil

        MAX_PAGES.times do
          data = yield(start_ms, end_ms, cursor) || {}
          page = Array(data["list"])
          rows.concat(page)

          cursor = data["cursor"].presence
          break if cursor.nil? || page.empty?
        end
      end

      rows
    end

    def history_windows
      window_length = Provider::Bitget::MAX_WINDOW_DAYS.days
      finish = Time.current
      start = [
        bitget_item.sync_start_date || Provider::Bitget::MAX_HISTORY_DAYS.days.ago,
        Provider::Bitget::MAX_HISTORY_DAYS.days.ago
      ].max

      windows = []
      cursor_time = start
      while cursor_time < finish
        window_end = [ cursor_time + window_length, finish ].min
        windows << [ to_ms(cursor_time), to_ms(window_end) ]
        cursor_time = window_end
      end

      windows
    end

    def to_ms(time)
      (time.to_f * 1000).round.to_s
    end

    def upsert_bitget_account(assets:, account_data:, fills:, financial_records:, total_usd:)
      bitget_item.bitget_accounts.find_or_initialize_by(account_id: "combined").tap do |account|
        account.assign_attributes(
          name: bitget_item.institution_name.presence || "Bitget",
          account_type: "combined",
          currency: "USD",
          current_balance: total_usd,
          institution_metadata: institution_metadata(assets),
          raw_payload: {
            "account" => account_data.except("assets"),
            "assets" => assets.map(&:stringify_keys),
            "fetched_at" => Time.current.iso8601
          },
          raw_transactions_payload: {
            "fills" => fills,
            "financial_records" => financial_records,
            "fetched_at" => Time.current.iso8601
          },
          extra: account.extra.to_h.deep_merge(price_metadata(assets))
        )
        account.save!
      end
    end

    def institution_metadata(assets)
      {
        "name" => "Bitget",
        "domain" => "bitget.com",
        "url" => "https://www.bitget.com",
        "color" => "#00F0FF",
        "asset_count" => assets.size,
        "assets" => assets.map { |asset| asset[:symbol] }
      }
    end

    def price_metadata(assets)
      missing = assets.select { |asset| asset[:price_status] == "missing" }.map { |asset| asset[:symbol] }

      { "bitget" => { "missing_prices" => missing, "stale_prices" => [] } }
    end
end
