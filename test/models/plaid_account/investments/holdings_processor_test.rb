require "test_helper"

class PlaidAccount::Investments::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @plaid_account = plaid_accounts(:one)
    @security_resolver = PlaidAccount::Investments::SecurityResolver.new(@plaid_account)
  end

  test "creates holding records from Plaid holdings snapshot" do
    test_investments_payload = {
      securities: [], # mocked
      holdings: [
        {
          "security_id" => "123",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        },
        {
          "security_id" => "456",
          "quantity" => 200,
          "institution_price" => 200,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: [] # not relevant for test
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "123")
                      .returns(
                        OpenStruct.new(
                          security: securities(:aapl),
                          cash_equivalent?: false,
                          brokerage_cash?: false
                        )
                      )

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "456")
                      .returns(
                        OpenStruct.new(
                          security: securities(:aapl),
                          cash_equivalent?: false,
                          brokerage_cash?: false
                        )
                      )

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 2 do
      processor.process
    end

    holdings = Holding.where(account: @plaid_account.current_account).order(:date)

    assert_equal 100, holdings.first.qty
    assert_equal 100, holdings.first.price
    assert_equal "USD", holdings.first.currency
    assert_equal securities(:aapl), holdings.first.security
    assert_equal 1.day.ago.to_date, holdings.first.date

    assert_equal 200, holdings.second.qty
    assert_equal 200, holdings.second.price
    assert_equal "USD", holdings.second.currency
    assert_equal securities(:aapl), holdings.second.security
    assert_equal Date.current, holdings.second.date
  end

  # Plaid does not delete future holdings because it doesn't support holdings deletion
  # (PlaidAdapter#can_delete_holdings? returns false). This test verifies that future
  # holdings are NOT deleted when processing Plaid holdings data.
  test "does not delete future holdings when processing Plaid holdings" do
    account = @plaid_account.current_account

    # Create account_provider
    account_provider = AccountProvider.create!(
      account: account,
      provider: @plaid_account
    )

    # Create a third security for testing
    third_security = Security.create!(ticker: "GOOGL", name: "Google", exchange_operating_mic: "XNAS", country_code: "US")

    # Create a future AAPL holding that should NOT be deleted
    future_aapl_holding = account.holdings.create!(
      security: securities(:aapl),
      date: Date.current,
      qty: 80,
      price: 180,
      amount: 14400,
      currency: "USD",
      account_provider_id: account_provider.id
    )

    # Plaid returns holdings from yesterday - future holdings should remain
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "current",
          "quantity" => 50,
          "institution_price" => 50,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => Date.current
        },
        {
          "security_id" => "clean",
          "quantity" => 75,
          "institution_price" => 75,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        },
        {
          "security_id" => "past",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    # Mock security resolver for all three securities
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "current")
                      .returns(OpenStruct.new(security: securities(:msft), cash_equivalent?: false, brokerage_cash?: false))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "clean")
                      .returns(OpenStruct.new(security: third_security, cash_equivalent?: false, brokerage_cash?: false))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "past")
                      .returns(OpenStruct.new(security: securities(:aapl), cash_equivalent?: false, brokerage_cash?: false))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)
    processor.process

    # Should have created 3 new holdings PLUS the existing future holding (total 4)
    assert_equal 4, account.holdings.count

    # Future AAPL holding should still exist (NOT deleted)
    assert account.holdings.exists?(future_aapl_holding.id)

    # Should have the correct holdings from Plaid
    assert account.holdings.exists?(security: securities(:msft), date: Date.current, qty: 50)
    assert account.holdings.exists?(security: third_security, date: 1.day.ago.to_date, qty: 75)
    assert account.holdings.exists?(security: securities(:aapl), date: 1.day.ago.to_date, qty: 100)
  end

  test "marks all holdings from one Plaid response as the current snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    stale = account.holdings.create!(
      security: securities(:msft),
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account_provider
    )
    @plaid_account.update!(raw_holdings_payload: {
      "holdings" => [
        {
          "security_id" => "current",
          "quantity" => 2,
          "institution_price" => 150,
          "iso_currency_code" => "USD",
          "institution_price_as_of" => 1.day.ago.to_date
        }
      ]
    })
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "current")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    described_processor.process

    current = account.holdings.find_by!(security: securities(:aapl), qty: 2)
    assert_equal account_provider.reload.current_holding_snapshot_id, current.provider_snapshot_id
    assert_not_equal current.provider_snapshot_id, stale.provider_snapshot_id
    assert_equal [ current.id ], account.current_holdings.pluck(:id)
  end

  test "an empty Plaid response advances to an empty current snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    account.holdings.create!(
      security: securities(:aapl),
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account_provider
    )
    @plaid_account.update!(raw_holdings_payload: { "holdings" => [] })

    described_processor.process

    assert account_provider.reload.current_holding_snapshot_id.present?
    assert_empty account.current_holdings
  end

  test "a missing Plaid response preserves the current snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    snapshot_id = SecureRandom.uuid
    account_provider.update!(current_holding_snapshot_id: snapshot_id)
    @plaid_account.update!(raw_holdings_payload: nil)

    described_processor.process

    assert_equal snapshot_id, account_provider.reload.current_holding_snapshot_id
  end

  test "brokerage cash does not prevent a completed snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    @plaid_account.update!(raw_holdings_payload: {
      "holdings" => [ { "security_id" => "cash", "quantity" => 100, "institution_price" => 1 } ]
    })
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "cash")
                      .returns(OpenStruct.new(security: nil, brokerage_cash?: true))

    described_processor.process

    assert account_provider.reload.current_holding_snapshot_id.present?
    assert_empty account.current_holdings
  end

  test "an incomplete response does not modify an existing current snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    snapshot_id = SecureRandom.uuid
    current = account.holdings.create!(
      security: securities(:aapl),
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD",
      account_provider: account_provider,
      provider_snapshot_id: snapshot_id
    )
    account_provider.update!(current_holding_snapshot_id: snapshot_id)
    @plaid_account.update!(raw_holdings_payload: {
      "holdings" => [
        { "security_id" => "valid", "quantity" => 2, "institution_price" => 150 },
        { "security_id" => "invalid", "quantity" => 1, "institution_price" => 100 }
      ]
    })
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "valid")
                      .returns(OpenStruct.new(security: securities(:aapl), brokerage_cash?: false))
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "invalid")
                      .returns(OpenStruct.new(security: nil, brokerage_cash?: false))

    described_processor.process

    assert_equal snapshot_id, account_provider.reload.current_holding_snapshot_id
    assert_equal 1, current.reload.qty
    assert_equal 100, current.amount
  end

  test "a second sync on the same day removes a position missing from the response" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    initial_rows = [
      { "security_id" => "aapl", "quantity" => 2, "institution_price" => 150 },
      { "security_id" => "msft", "quantity" => 1, "institution_price" => 100 }
    ]
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl").returns(OpenStruct.new(security: securities(:aapl)))
    @security_resolver.stubs(:resolve).with(plaid_security_id: "msft").returns(OpenStruct.new(security: securities(:msft)))
    @plaid_account.update!(raw_holdings_payload: { "holdings" => initial_rows })
    described_processor.process
    first_snapshot_id = account_provider.reload.current_holding_snapshot_id

    @plaid_account.update!(raw_holdings_payload: { "holdings" => [ initial_rows.first.merge("quantity" => 3) ] })
    described_processor.process

    assert_not_equal first_snapshot_id, account_provider.reload.current_holding_snapshot_id
    assert_equal [ securities(:aapl).id ], account.current_holdings.pluck(:security_id)
    assert_equal [ 3.to_d ], account.current_holdings.pluck(:qty)
    assert account.holdings.exists?(security: securities(:msft)), "Historical positions must not be deleted"
    assert_equal account.current_holdings.pluck(:id),
                 Holding::CurrentForInvestmentAccounts.new([ account.id ]).relation.pluck(:id)
  end

  test "a failed holding write rolls back earlier rows and preserves the current snapshot" do
    account = @plaid_account.current_account
    account_provider = AccountProvider.create!(account: account, provider: @plaid_account)
    @security_resolver.stubs(:resolve).with(plaid_security_id: "aapl").returns(OpenStruct.new(security: securities(:aapl)))
    @security_resolver.stubs(:resolve).with(plaid_security_id: "msft").returns(OpenStruct.new(security: securities(:msft)))
    @plaid_account.update!(raw_holdings_payload: {
      "holdings" => [ { "security_id" => "aapl", "quantity" => 1, "institution_price" => 150 } ]
    })
    described_processor.process
    snapshot_id = account_provider.reload.current_holding_snapshot_id
    current = account.current_holdings.sole

    @plaid_account.update!(raw_holdings_payload: {
      "holdings" => [
        { "security_id" => "aapl", "quantity" => 3, "institution_price" => 150 },
        { "security_id" => "msft", "quantity" => -1, "institution_price" => 100 }
      ]
    })

    assert_raises ActiveRecord::RecordInvalid do
      described_processor.process
    end

    assert_equal snapshot_id, account_provider.reload.current_holding_snapshot_id
    assert_equal 1, current.reload.qty
    assert_equal [ current.id ], account.current_holdings.pluck(:id)
  end

  test "a malformed holdings payload is not treated as a complete empty response" do
    account_provider = AccountProvider.create!(account: @plaid_account.current_account, provider: @plaid_account)
    snapshot_id = SecureRandom.uuid
    account_provider.update!(current_holding_snapshot_id: snapshot_id)

    [ {}, { "holdings" => nil }, { "holdings" => {} } ].each do |payload|
      @plaid_account.update!(raw_holdings_payload: payload)
      described_processor.process
      assert_equal snapshot_id, account_provider.reload.current_holding_snapshot_id
    end
  end

  test "continues processing other holdings when security resolution fails" do
    account_provider = AccountProvider.create!(account: @plaid_account.current_account, provider: @plaid_account)
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "fail",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "success",
          "quantity" => 200,
          "institution_price" => 200,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    # First security fails to resolve
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "fail")
                      .returns(OpenStruct.new(security: nil))

    # Second security succeeds
    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "success")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    # Should create only 1 holding (the successful one)
    assert_difference "Holding.count", 1 do
      processor.process
    end

    # Should have created the successful holding
    assert @plaid_account.current_account.holdings.exists?(security: securities(:aapl), qty: 200)
    assert_nil account_provider.reload.current_holding_snapshot_id
  end

  test "handles string values and computes amount using BigDecimal arithmetic" do
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "string_values",
          "quantity" => "10.5",
          "institution_price" => "150.75",
          "iso_currency_code" => "USD",
          "institution_price_as_of" => "2025-01-15"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "string_values")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 1 do
      processor.process
    end

    holding = @plaid_account.current_account.holdings.find_by(
      security: securities(:aapl),
      date: Date.parse("2025-01-15"),
      currency: "USD"
    )

    assert_not_nil holding, "Expected to find holding for AAPL on 2025-01-15"
    assert_equal BigDecimal("10.5"), holding.qty
    assert_equal BigDecimal("150.75"), holding.price
    assert_equal BigDecimal("1582.875"), holding.amount  # 10.5 * 150.75 using BigDecimal
    assert_equal Date.parse("2025-01-15"), holding.date
  end

  test "skips holdings with nil quantity or price" do
    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "missing_quantity",
          "quantity" => nil,
          "institution_price" => 100,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "missing_price",
          "quantity" => 100,
          "institution_price" => nil,
          "iso_currency_code" => "USD"
        },
        {
          "security_id" => "valid",
          "quantity" => 50,
          "institution_price" => 50,
          "iso_currency_code" => "USD"
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "missing_quantity")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "missing_price")
                      .returns(OpenStruct.new(security: securities(:msft)))

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "valid")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    # Should create only 1 holding (the valid one)
    assert_difference "Holding.count", 1 do
      processor.process
    end

    # Should have created only the valid holding
    assert @plaid_account.current_account.holdings.exists?(security: securities(:aapl), qty: 50, price: 50)
    assert_not @plaid_account.current_account.holdings.exists?(security: securities(:msft))
  end

  test "uses account currency as fallback when Plaid omits iso_currency_code" do
    account = @plaid_account.current_account

    # Ensure the account has a currency
    account.update!(currency: "EUR")

    test_investments_payload = {
      securities: [],
      holdings: [
        {
          "security_id" => "no_currency",
          "quantity" => 100,
          "institution_price" => 100,
          "iso_currency_code" => nil,  # Plaid omits currency
          "institution_price_as_of" => Date.current
        }
      ],
      transactions: []
    }

    @plaid_account.update!(raw_holdings_payload: test_investments_payload)

    @security_resolver.expects(:resolve)
                      .with(plaid_security_id: "no_currency")
                      .returns(OpenStruct.new(security: securities(:aapl)))

    processor = PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)

    assert_difference "Holding.count", 1 do
      processor.process
    end

    holding = account.holdings.find_by(security: securities(:aapl))
    assert_equal "EUR", holding.currency  # Should use account's currency
  end

  private
    def described_processor
      PlaidAccount::Investments::HoldingsProcessor.new(@plaid_account, security_resolver: @security_resolver)
    end
end
