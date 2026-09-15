class AddProviderSnapshotIdsToHoldings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :account_providers, :current_holding_snapshot_id, :uuid
    add_column :holdings, :provider_snapshot_id, :uuid
    add_index :holdings, [ :account_provider_id, :provider_snapshot_id ],
              name: "idx_holdings_on_provider_and_snapshot",
              algorithm: :concurrently
  end
end
