# frozen_string_literal: true

require "test_helper"

class BitgetItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = BitgetItem.create!(
      family: @family,
      name: "Bitget",
      api_key: "k",
      api_secret: "s",
      passphrase: "p"
    )
    @provider = mock
    @provider.stubs(:get_fills).returns({ "list" => [], "cursor" => nil })
    @provider.stubs(:get_financial_records).returns({ "list" => [], "cursor" => nil })
    @provider.stubs(:get_funding_assets).returns([])
    @provider.stubs(:get_elite_assets).returns({ "resultList" => [] })
    @provider.stubs(:get_spot_tickers).returns(spot_tickers)
  end

  test "creates a combined bitget account from account assets" do
    @provider.stubs(:get_account_assets).returns(account_assets)

    assert_difference "@item.bitget_accounts.count", 1 do
      BitgetItem::Importer.new(@item, bitget_provider: @provider).import
    end

    account = @item.bitget_accounts.first
    assert_equal "combined", account.account_id
    assert_equal "combined", account.account_type
    assert_equal "USD", account.currency
    # accountEquity is authoritative, not the sum of the per-coin usdValue.
    assert_in_delta 11.14, account.current_balance, 0.01

    btc = account.raw_payload["assets"].find { |asset| asset["symbol"] == "BTC" }
    assert_equal "exact", btc["price_status"]
    assert_in_delta 50_000, btc["price_usd"].to_d, 0.01
  end

  test "derives per-coin usd price from usdValue and equity" do
    @provider.stubs(:get_account_assets).returns(
      "accountEquity" => "100",
      "assets" => [
        { "coin" => "ETH", "equity" => "2", "usdValue" => "5000", "balance" => "2", "available" => "2", "locked" => "0", "debt" => "0" }
      ]
    )

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    eth = @item.bitget_accounts.first.raw_payload["assets"].first
    assert_equal "ETH", eth["symbol"]
    assert_in_delta 2500, eth["price_usd"].to_d, 0.01
    assert_in_delta 5000, eth["amount_usd"].to_d, 0.01
  end

  test "marks assets without a usd valuation as missing prices" do
    @provider.stubs(:get_account_assets).returns(
      "accountEquity" => "0",
      "assets" => [
        { "coin" => "XYZ", "equity" => "10", "usdValue" => nil, "balance" => "10", "available" => "10", "locked" => "0", "debt" => "0" }
      ]
    )

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    account = @item.bitget_accounts.first
    assert_equal "missing", account.raw_payload["assets"].first["price_status"]
    assert_includes account.extra.dig("bitget", "missing_prices"), "XYZ"
  end

  test "skips coins with no balance and no locked amount" do
    @provider.stubs(:get_account_assets).returns(
      "accountEquity" => "0",
      "assets" => [
        { "coin" => "USDT", "equity" => "0", "usdValue" => "0", "balance" => "0", "available" => "0", "locked" => "0", "debt" => "0" },
        { "coin" => "BGB", "equity" => "0", "usdValue" => "0", "balance" => "0", "available" => "0", "locked" => "3", "debt" => "0" }
      ]
    )

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    symbols = @item.bitget_accounts.first.raw_payload["assets"].map { |asset| asset["symbol"] }
    assert_equal [ "BGB" ], symbols
  end

  test "falls back to summing usdValue when accountEquity is absent" do
    @provider.stubs(:get_account_assets).returns(
      "assets" => [
        { "coin" => "BTC", "equity" => "1", "usdValue" => "60000", "balance" => "1", "available" => "1", "locked" => "0", "debt" => "0" },
        { "coin" => "USDT", "equity" => "40", "usdValue" => "40", "balance" => "40", "available" => "40", "locked" => "0", "debt" => "0" }
      ]
    )

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    assert_in_delta 60_040, @item.bitget_accounts.first.current_balance, 0.01
  end

  test "indexes fills by execId and financial records by id" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_fills).returns(
      { "list" => [ { "execId" => "e1", "symbol" => "BTCUSDT" } ], "cursor" => nil }
    )
    @provider.stubs(:get_financial_records).returns(
      { "list" => [ { "id" => "r1", "coin" => "USDT" } ], "cursor" => nil }
    )

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    payload = @item.bitget_accounts.first.raw_transactions_payload
    assert_equal [ "e1" ], payload["fills"].keys
    assert_equal [ "r1" ], payload["financial_records"].keys
    assert_equal 1, result[:fills_imported]
    assert_equal 1, result[:financial_records_imported]
  end

  test "keeps holdings and fills when financial records are not permitted" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_financial_records).raises(Provider::Bitget::PermissionError.new("Incorrect permissions"))

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    assert result[:success]
    assert_equal 0, result[:financial_records_imported]
    assert_equal 2, result[:assets_imported]
    assert_equal "good", @item.reload.status
  end

  test "flags the item for reconnection when the account call is not permitted" do
    @provider.stubs(:get_account_assets).raises(Provider::Bitget::PermissionError.new("Incorrect permissions"))

    assert_raises(Provider::Bitget::PermissionError) do
      BitgetItem::Importer.new(@item, bitget_provider: @provider).import
    end

    assert_equal "requires_update", @item.reload.status
  end

  test "windows history into chunks no larger than the api allows" do
    @item.update!(sync_start_date: 85.days.ago)
    windows = BitgetItem::Importer.new(@item, bitget_provider: @provider).send(:history_windows)

    assert windows.size >= 3, "expected 85 days to split into multiple windows"
    windows.each do |start_ms, end_ms|
      span_days = (end_ms.to_i - start_ms.to_i) / 86_400_000.0
      assert_operator span_days, :<=, Provider::Bitget::MAX_WINDOW_DAYS
    end
  end

  test "never requests history older than the api retains" do
    @item.update!(sync_start_date: 3.years.ago)
    windows = BitgetItem::Importer.new(@item, bitget_provider: @provider).send(:history_windows)

    earliest = Time.zone.at(windows.first.first.to_i / 1000)
    assert_operator earliest, :>=, (Provider::Bitget::MAX_HISTORY_DAYS + 1).days.ago
  end

  test "imports funding account balances priced from the public ticker table" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_funding_assets).returns([
      { "coin" => "ETH", "available" => "1.5", "frozen" => "0.5", "balance" => "2.0" },
      { "coin" => "USDT", "available" => "100", "frozen" => "0", "balance" => "100" }
    ])

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    funding = @item.bitget_accounts.first.raw_payload["assets"].select { |a| a["source"] == "funding" }
    eth = funding.find { |a| a["symbol"] == "ETH" }

    assert_in_delta 2500, eth["price_usd"].to_d, 0.01
    assert_in_delta 5000, eth["amount_usd"].to_d, 0.01
    assert_equal "0.5", eth["locked"]
    # Stablecoins are worth a dollar without needing a ticker.
    assert_in_delta 100, funding.find { |a| a["symbol"] == "USDT" }["amount_usd"].to_d, 0.01
  end

  test "imports Earn positions using Bitget's own USD valuation" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_elite_assets).returns({ "resultList" => [
      elite_row(coin: "BGUSD", amount: "500", usd: "500.5"),
      elite_row(coin: "BGSOL", amount: "2", usd: "300")
    ] })

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    earn = @item.bitget_accounts.first.raw_payload["assets"].select { |a| a["source"] == "earn" }
    bgusd = earn.find { |a| a["symbol"] == "BGUSD" }

    # holdingAmount only - the 25.0 of totalProfit must not be added on top.
    assert_in_delta 500, bgusd["balance"].to_d, 0.01
    # usdtHoldingAmount is used directly rather than a ticker lookup, so the
    # small premium over principal survives.
    assert_in_delta 500.5, bgusd["amount_usd"].to_d, 0.01
    assert_equal "exact", bgusd["price_status"]
    assert_in_delta 150, earn.find { |a| a["symbol"] == "BGSOL" }["price_usd"].to_d, 0.01
  end

  test "falls back to the ticker table when Earn omits a USD valuation" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_elite_assets).returns({ "resultList" => [
      elite_row(coin: "ETH", amount: "2", usd: nil)
    ] })

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    eth = @item.bitget_accounts.first.raw_payload["assets"].find { |a| a["source"] == "earn" }
    assert_in_delta 5000, eth["amount_usd"].to_d, 0.01
  end

  test "total equity sums all three pots" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_funding_assets).returns([
      { "coin" => "USDT", "available" => "100", "frozen" => "0", "balance" => "100" }
    ])
    @provider.stubs(:get_elite_assets).returns({ "resultList" => [
      elite_row(coin: "BGUSD", amount: "500", usd: "500")
    ] })

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    # accountEquity 11.14 (trading) + 100 (funding) + 500 (earn)
    assert_in_delta 611.14, @item.bitget_accounts.first.current_balance, 0.01
    assert_equal({ "spot" => 2, "funding" => 1, "earn" => 1 }, result[:assets_by_source])
  end

  test "the same coin in several pots becomes several assets, not one" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_funding_assets).returns([
      { "coin" => "USDT", "available" => "100", "frozen" => "0", "balance" => "100" }
    ])

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    usdt = @item.bitget_accounts.first.raw_payload["assets"].select { |a| a["symbol"] == "USDT" }
    assert_equal %w[spot funding], usdt.map { |a| a["source"] }
  end

  test "keeps the trading account when the key cannot read funding or Earn" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_funding_assets).raises(Provider::Bitget::PermissionError.new("Incorrect permissions"))
    @provider.stubs(:get_elite_assets).raises(Provider::Bitget::PermissionError.new("Incorrect permissions"))

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    assert result[:success]
    assert_equal({ "spot" => 2 }, result[:assets_by_source])
    assert_equal "good", @item.reload.status
  end

  test "marks funding coins with no ticker as missing prices" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_funding_assets).returns([
      { "coin" => "NOSUCHCOIN", "available" => "10", "frozen" => "0", "balance" => "10" }
    ])

    BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    account = @item.bitget_accounts.first
    row = account.raw_payload["assets"].find { |a| a["symbol"] == "NOSUCHCOIN" }
    assert_equal "missing", row["price_status"]
    assert_includes account.extra.dig("bitget", "missing_prices"), "NOSUCHCOIN"
  end

  test "an unreachable ticker table does not fail the sync" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_spot_tickers).raises(Provider::Bitget::ApiError.new("service busy"))
    @provider.stubs(:get_funding_assets).returns([
      { "coin" => "ETH", "available" => "2", "frozen" => "0", "balance" => "2" }
    ])

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    assert result[:success]
    row = @item.bitget_accounts.first.raw_payload["assets"].find { |a| a["symbol"] == "ETH" }
    assert_equal "missing", row["price_status"]
  end

  test "a Bitget-side Earn failure does not take the sync down" do
    @provider.stubs(:get_account_assets).returns(account_assets)
    @provider.stubs(:get_elite_assets).raises(
      Provider::Bitget::ApiError.new("You are in Unified Account mode, and the Classic Account API is not supported at this time (code 40085)")
    )

    result = BitgetItem::Importer.new(@item, bitget_provider: @provider).import

    assert result[:success]
    assert_equal({ "spot" => 2 }, result[:assets_by_source])
  end

  private

    def account_assets
      {
        "accountEquity" => "11.13919278",
        "assets" => [
          { "coin" => "BTC", "equity" => "0.0001", "usdValue" => "5.0", "balance" => "0.0001", "available" => "0.0001", "locked" => "0", "debt" => "0" },
          { "coin" => "USDT", "equity" => "6.19300826", "usdValue" => "6.19299777", "balance" => "6.19300826", "available" => "6.19300826", "locked" => "0", "debt" => "0" }
        ]
      }
    end

    def spot_tickers
      [
        { "symbol" => "BTCUSDT", "lastPr" => "60000" },
        { "symbol" => "ETHUSDT", "lastPr" => "2500" },
        { "symbol" => "BTCUSDC", "lastPr" => "60010" }
      ]
    end

    def elite_row(coin:, amount:, usd:)
      {
        "productId" => "p-#{coin}",
        "productCoin" => coin,
        "holdingAmount" => amount,
        "usdtHoldingAmount" => usd,
        "exchangeRate" => "1",
        "totalProfit" => "25.0"
      }
    end
end
