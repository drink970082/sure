# frozen_string_literal: true

# Extended onto Account from config/initializers/fork_providers.rb instead of
# adding create_from_bitget_account directly to app/models/account.rb, keeping
# that upstream file untouched.
#
# Account.create_from_crypto_exchange_account is private on the singleton, so
# this calls it through send - the alternative is editing account.rb, which is
# exactly what this file exists to avoid.
module Account::BitgetCreatable
  def create_from_bitget_account(bitget_account)
    send(
      :create_from_crypto_exchange_account,
      bitget_account,
      family: bitget_account.bitget_item.family
    )
  end
end
