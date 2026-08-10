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
end
