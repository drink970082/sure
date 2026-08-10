# frozen_string_literal: true

class BitgetItem::Importer
  # Guards against a pathological cursor loop. Each page holds up to 100 rows
  # and Bitget only serves 90 days, so this ceiling is never reached in practice.
  MAX_PAGES_PER_WINDOW = 100

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
    assets = parse_assets(account_data)
    fills = fetch_fills
    financial_records = fetch_financial_records

    total_usd = total_usd_for(account_data, assets)

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
      fills_imported: fills.size,
      financial_records_imported: financial_records.size,
      total_usd: total_usd
    }
  rescue Provider::Bitget::PermissionError => e
    bitget_item.update!(status: :requires_update)
    raise e
  end

  private

    # Bitget already reports a per-coin USD valuation, so unlike Kraken there is
    # no per-symbol ticker lookup here - usdValue is the price source.
    def parse_assets(account_data)
      Array(account_data["assets"]).filter_map do |asset|
        symbol = asset["coin"].to_s.upcase
        next if symbol.blank?

        balance = asset["equity"].presence&.to_d || asset["balance"].to_d
        locked = asset["locked"].to_d
        next if balance.zero? && locked.zero?

        usd_value = asset["usdValue"].presence&.to_d
        price_usd = if usd_value && !balance.zero?
          (usd_value / balance)
        end

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

    # accountEquity is Bitget's own USD valuation of the whole account and is
    # authoritative; summing per-coin values is only a fallback.
    def total_usd_for(account_data, assets)
      equity = account_data["accountEquity"].presence&.to_d
      return equity.round(2) if equity

      assets.sum { |asset| asset[:amount_usd].to_d }.round(2)
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

        MAX_PAGES_PER_WINDOW.times do
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
