# frozen_string_literal: true

# Fork-only migration.
#
# A far-future timestamp would keep this sorted after anything upstream adds,
# but Rails 7.2 rejects migration timestamps ahead of the current time
# (ActiveRecord::InvalidMigrationTimestampError), so this carries an ordinary
# one. When an upstream rebase brings in a newer migration, resolve the
# db/schema.rb conflict by taking their version and re-running db:migrate
# rather than hand-editing it.
class CreateBitgetItemsAndAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :bitget_items, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.string :name

      t.string :institution_name
      t.string :institution_domain
      t.string :institution_url
      t.string :institution_color

      t.string :status, default: "good", null: false
      t.boolean :scheduled_for_deletion, default: false, null: false
      t.boolean :pending_account_setup, default: false, null: false

      t.datetime :sync_start_date
      t.jsonb :raw_payload

      t.text :api_key
      t.text :api_secret
      t.text :passphrase

      t.timestamps
    end

    add_index :bitget_items, :status

    create_table :bitget_accounts, id: :uuid do |t|
      t.references :bitget_item, null: false, foreign_key: true, type: :uuid

      t.string :name
      t.string :account_id, null: false
      t.string :account_type
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload
      t.jsonb :extra, default: {}, null: false

      t.timestamps
    end

    add_index :bitget_accounts, :account_type
    add_index :bitget_accounts,
              [ :bitget_item_id, :account_id ],
              unique: true,
              name: "index_bitget_accounts_on_item_and_account_id"
  end
end
