require "test_helper"
require "concurrent"
require "timeout"

class Account::ProviderHoldingSnapshotConcurrencyTest < ActiveSupport::TestCase
  # Readers and competing imports need separate connections and real commits.
  self.use_transactional_tests = false

  setup do
    @family = Family.create!(name: "Holding snapshots", currency: "USD")
    @account = @family.accounts.create!(name: "Investments", currency: "USD", balance: 0, accountable: Investment.new)
    item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    provider_account = item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    @account_provider = AccountProvider.create!(account: @account, provider: provider_account)
    @first_security = Security.create!(ticker: "SNAPSHOT-FIRST-#{SecureRandom.hex(4)}", name: "First")
    @second_security = Security.create!(ticker: "SNAPSHOT-SECOND-#{SecureRandom.hex(4)}", name: "Second")
  end

  teardown do
    @family.destroy!
    @first_security.destroy!
    @second_security.destroy!
  end

  test "readers see completed snapshots and overlapping imports publish in order" do
    initial_snapshot_id = import_snapshot(@first_security, quantity: 1)
    first_written = Concurrent::Event.new
    release_first = Concurrent::Event.new
    second_entered = Concurrent::Event.new
    second_pid = Queue.new

    first_import = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        import_snapshot(@first_security, quantity: 2) do
          first_written.set
          raise "First import was not released" unless release_first.wait(10)
        end
      end
    end

    assert first_written.wait(5), "First import must reach its uncommitted write"
    assert_equal initial_snapshot_id, @account_provider.reload.current_holding_snapshot_id
    assert_equal [ 1.to_d ], @account.current_holdings.pluck(:qty)

    second_import = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        second_pid << connection.select_value("SELECT pg_backend_pid()")
        import_snapshot(@second_security, quantity: 3) { second_entered.set }
      end
    end

    Timeout.timeout(5) do
      pid = second_pid.pop
      until ActiveRecord::Base.connection.select_value("SELECT wait_event_type = 'Lock' FROM pg_stat_activity WHERE pid = #{Integer(pid)}")
        second_entered.wait(0.01)
        assert_not second_entered.set?, "Second import must wait for the first snapshot to commit"
      end
    end

    release_first.set
    first_import.value
    second_snapshot_id = second_import.value

    assert_equal second_snapshot_id, @account_provider.reload.current_holding_snapshot_id
    assert_equal [ @second_security.id ], @account.current_holdings.pluck(:security_id)
    assert_equal [ 3.to_d ], @account.current_holdings.pluck(:qty)
  ensure
    release_first&.set
    [ first_import, second_import ].compact.each(&:join)
  end

  private
    def import_snapshot(security, quantity:)
      account = Account.find(@account.id)
      account_provider = AccountProvider.find(@account_provider.id)
      adapter = Account::ProviderImportAdapter.new(account)

      adapter.import_holding_snapshot(account_provider: account_provider) do
        adapter.import_holding(
          security: security, quantity: quantity, amount: quantity * 100,
          currency: "USD", date: Date.current, price: 100, source: "coinstats",
          account_provider_id: account_provider.id
        )
        yield if block_given?
      end
    end
end
