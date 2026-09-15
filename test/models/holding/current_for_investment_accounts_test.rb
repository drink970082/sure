require "test_helper"

class Holding::CurrentForInvestmentAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Investment",
      balance: 2100,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "returns the latest provider import day while preserving per-security price dates" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    current_holding = create_holding("AAPL", date: Date.current, account_provider: account_provider)
    stale_holding = create_holding("STALE", date: 1.day.ago.to_date, account_provider: account_provider)
    older_price_current_holding = create_holding("MSFT", date: 1.day.ago.to_date, account_provider: account_provider)
    stale_holding.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)

    assert_equal [ current_holding.id, older_price_current_holding.id ].sort,
                 described_query.pluck(:id).sort
  end

  test "returns holdings from the latest completed provider import" do
    account_provider = create_account_provider
    older_snapshot_id = SecureRandom.uuid
    latest_snapshot_id = SecureRandom.uuid
    account_provider.update!(current_holding_snapshot_id: latest_snapshot_id)

    stale = create_holding("STALE", date: Date.current, account_provider: account_provider)
    stale.update!(provider_snapshot_id: older_snapshot_id)
    current = create_holding("CURRENT", date: 1.day.ago.to_date, account_provider: account_provider)
    current.update!(provider_snapshot_id: latest_snapshot_id)

    assert_equal [ current.id ], described_query.pluck(:id)
  end

  test "a completed empty provider import makes prior holdings non-current" do
    account_provider = create_account_provider
    stale = create_holding("STALE", date: Date.current, account_provider: account_provider)
    stale.update!(provider_snapshot_id: SecureRandom.uuid)
    account_provider.update!(current_holding_snapshot_id: SecureRandom.uuid)

    assert_empty described_query
  end

  test "selects each provider's current snapshot independently" do
    first_provider = create_account_provider
    second_provider = create_coinbase_account_provider
    first_snapshot_id = SecureRandom.uuid
    second_snapshot_id = SecureRandom.uuid
    first_provider.update!(current_holding_snapshot_id: first_snapshot_id)
    second_provider.update!(current_holding_snapshot_id: second_snapshot_id)

    first_current = create_holding("FIRST", date: 2.days.ago.to_date, account_provider: first_provider)
    first_current.update!(provider_snapshot_id: first_snapshot_id)
    second_stale = create_holding("STALE", date: Date.current, account_provider: second_provider)
    second_stale.update!(provider_snapshot_id: SecureRandom.uuid)
    second_current = create_holding("SECOND", date: 1.day.ago.to_date, account_provider: second_provider)
    second_current.update!(provider_snapshot_id: second_snapshot_id)

    assert_equal [ first_current.id, second_current.id ].sort,
                 described_query.pluck(:id).sort
  end

  test "an initial empty snapshot excludes historical manual and calculated holdings" do
    calculated = create_holding("CALCULATED", date: Date.current)
    account_provider = create_account_provider
    account_provider.update!(current_holding_snapshot_id: SecureRandom.uuid)

    assert_empty described_query
    assert_empty @account.current_holdings
    assert Holding.exists?(calculated.id), "Historical rows must be retained"
  end

  test "keeps an unmigrated provider current independently of a newer snapshot provider" do
    snapshot_provider = create_account_provider
    legacy_provider = create_coinbase_account_provider
    snapshot_id = SecureRandom.uuid
    snapshot_provider.update!(current_holding_snapshot_id: snapshot_id)
    current = create_holding("CURRENT", date: Date.current, account_provider: snapshot_provider)
    current.update!(provider_snapshot_id: snapshot_id)
    legacy = create_holding("LEGACY", date: 1.day.ago.to_date, account_provider: legacy_provider)
    legacy.update_columns(updated_at: 1.day.ago)
    stale = create_holding("STALE", date: 2.days.ago.to_date, account_provider: legacy_provider)
    stale.update_columns(updated_at: 2.days.ago)

    expected = [ current.id, legacy.id ].sort
    assert_equal expected, described_query.pluck(:id).sort
    assert_equal expected, @account.current_holdings.pluck(:id).sort
  end

  test "changing a historical holding does not make it current in snapshot mode" do
    account_provider = create_account_provider
    snapshot_id = SecureRandom.uuid
    account_provider.update!(current_holding_snapshot_id: snapshot_id)
    current = create_holding("CURRENT", date: 1.day.ago.to_date, account_provider: account_provider)
    current.update!(provider_snapshot_id: snapshot_id)
    historical = create_holding("HISTORICAL", date: 2.days.ago.to_date, account_provider: account_provider)
    historical.update!(provider_snapshot_id: SecureRandom.uuid, cost_basis: 90)

    assert_equal [ current.id ], described_query.pluck(:id)
  end

  test "returns the latest holding per security for a manual account" do
    security = Security.create!(ticker: "AAPL", name: "Apple")
    create_holding_for_security(security, date: 2.days.ago.to_date, qty: 1)
    latest = create_holding_for_security(security, date: Date.current, qty: 2)

    assert_equal [ latest.id ], described_query.pluck(:id)
  end

  private
    def described_query
      Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    end

    def create_holding(ticker, date:, account_provider: nil)
      security = Security.create!(ticker: ticker, name: ticker)
      create_holding_for_security(security, date: date, account_provider: account_provider)
    end

    def create_account_provider
      coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: SecureRandom.hex)
      coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
      AccountProvider.create!(account: @account, provider: coinstats_account)
    end

    def create_coinbase_account_provider
      coinbase_item = CoinbaseItem.create!(family: @family, name: "Coinbase", api_key: "key", api_secret: "secret")
      coinbase_account = coinbase_item.coinbase_accounts.create!(name: "Second brokerage", currency: "USD")
      AccountProvider.create!(account: @account, provider: coinbase_account)
    end

    def create_holding_for_security(security, date:, qty: 1, account_provider: nil)
      @account.holdings.create!(
        security: security,
        date: date,
        qty: qty,
        price: 100,
        amount: qty * 100,
        currency: "USD",
        account_provider: account_provider
      )
    end
end
