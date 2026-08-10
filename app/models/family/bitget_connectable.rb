# frozen_string_literal: true

# Mixed into Family from config/initializers/fork_providers.rb rather than by
# editing the include list in app/models/family.rb - that single line is edited
# by upstream on every new provider and is a guaranteed rebase conflict.
module Family::BitgetConnectable
  extend ActiveSupport::Concern

  included do
    has_many :bitget_items, dependent: :destroy
  end

  def can_connect_bitget?
    true
  end

  def create_bitget_item!(api_key:, api_secret:, passphrase:, item_name: nil)
    item = bitget_items.create!(
      name: item_name || "Bitget",
      api_key: api_key,
      api_secret: api_secret,
      passphrase: passphrase
    )

    item.set_bitget_institution_defaults!
    item.sync_later
    item
  end

  def has_bitget_credentials?
    bitget_items.active.any?(&:credentials_configured?)
  end
end
