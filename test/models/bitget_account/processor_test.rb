# frozen_string_literal: true

require "test_helper"

class BitgetAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")

    @item = BitgetItem.create!(
      family: @family,
      name: "Bitget",
      api_key: "k",
      api_secret: "s",
      passphrase: "p"
    )

    @bitget_account = @item.bitget_accounts.create!(
      name: "Bitget",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 1000,
      raw_payload: { "assets" => [ { "symbol" => "BTC", "price_usd" => "50000", "balance" => "0.5" } ] },
      raw_transactions_payload: { "fills" => {}, "financial_records" => {} }
    )

    @account = Account.create!(
      family: @family,
      name: "Bitget",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: Crypto.new(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @bitget_account)
  end

  test "splits concatenated spot symbols into base and quote" do
    processor = BitgetAccount::Processor.new(@bitget_account)

    assert_equal [ "BTC", "USDT" ], processor.send(:split_symbol, "BTCUSDT")
    assert_equal [ "ETH", "USDC" ], processor.send(:split_symbol, "ETHUSDC")
    assert_equal [ "BTC", "FDUSD" ], processor.send(:split_symbol, "BTCFDUSD")
    assert_equal [ "ETH", "BTC" ], processor.send(:split_symbol, "ETHBTC")
  end

  test "unrecognised symbols fall back to a usdt quote rather than raising" do
    processor = BitgetAccount::Processor.new(@bitget_account)

    assert_equal [ "WEIRDCOIN", "USDT" ], processor.send(:split_symbol, "WEIRDCOIN")
  end

  test "maps every stablecoin quote onto USD" do
    processor = BitgetAccount::Processor.new(@bitget_account)

    assert_equal "USD", processor.send(:entry_currency_for, "USDT")
    assert_equal "USD", processor.send(:entry_currency_for, "FDUSD")
    assert_equal "USD", processor.send(:entry_currency_for, nil)
    # USDC is a valid Money currency and would pass through on its own, but it
    # is deliberately folded into USD too: mixing USDT entries in USD with USDC
    # entries in USDC would split one dollar-denominated book across two
    # currencies for no gain.
    assert_equal "USD", processor.send(:entry_currency_for, "USDC")
  end

  test "keeps genuinely non-dollar quotes in their own currency" do
    processor = BitgetAccount::Processor.new(@bitget_account)

    assert_equal "BTC", processor.send(:entry_currency_for, "BTC")
    assert_equal "EUR", processor.send(:entry_currency_for, "EUR")
    # Not an ISO currency and not a stablecoin - fall back rather than blow up.
    assert_equal "USD", processor.send(:entry_currency_for, "BGB")
  end

  test "creates a buy trade entry from a fill" do
    @bitget_account.update!(raw_transactions_payload: { "fills" => { "e1" => buy_fill } })

    assert_difference "@account.entries.count", 1 do
      BitgetAccount::Processor.new(@bitget_account).process
    end

    entry = @account.entries.find_by(external_id: "bitget_fill_e1")
    assert_equal "bitget", entry.source
    assert_equal "USD", entry.currency
    assert_equal(-1000, entry.amount)

    trade = entry.entryable
    assert_equal 0.02, trade.qty.to_f
    assert_equal 50_000, trade.price.to_f
    assert_equal "Buy", trade.investment_activity_label
  end

  test "creates a sell trade entry with inverted signs" do
    @bitget_account.update!(raw_transactions_payload: { "fills" => { "e2" => buy_fill.merge("execId" => "e2", "side" => "sell") } })

    BitgetAccount::Processor.new(@bitget_account).process

    entry = @account.entries.find_by(external_id: "bitget_fill_e2")
    assert_equal 1000, entry.amount
    assert_equal(-0.02, entry.entryable.qty.to_f)
    assert_equal "Sell", entry.entryable.investment_activity_label
  end

  test "fill processing is idempotent across repeated syncs" do
    @bitget_account.update!(raw_transactions_payload: { "fills" => { "e1" => buy_fill } })

    BitgetAccount::Processor.new(@bitget_account).process
    assert_no_difference "@account.entries.count" do
      BitgetAccount::Processor.new(@bitget_account.reload).process
    end
  end

  test "counts only fees charged in the quote coin" do
    processor = BitgetAccount::Processor.new(@bitget_account)
    fill = buy_fill.merge("feeDetail" => [
      { "feeCoin" => "USDT", "fee" => "-0.64" },
      { "feeCoin" => "BGB", "fee" => "-0.10" }
    ])

    assert_in_delta 0.64, processor.send(:fee_for, fill, "USDT"), 0.0001
  end

  test "sets the linked account balance from the exchange total" do
    BitgetAccount::Processor.new(@bitget_account).process

    assert_equal 1000, @account.reload.balance
    assert_equal 0, @account.cash_balance
  end

  private

    def buy_fill
      {
        "execId" => "e1",
        "orderId" => "o1",
        "category" => "SPOT",
        "symbol" => "BTCUSDT",
        "orderType" => "limit",
        "side" => "buy",
        "execPrice" => "50000",
        "execQty" => "0.02",
        "execValue" => "1000",
        "feeDetail" => [ { "feeCoin" => "USDT", "fee" => "-0.6" } ],
        "createdTime" => "1750141421721"
      }
    end
end
