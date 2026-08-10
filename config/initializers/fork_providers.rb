# frozen_string_literal: true

# Fork-only wiring.
#
# Upstream expects a new provider to edit the include list in family.rb and add
# a class method to account.rb. Both are single hot lines that upstream itself
# touches on every new provider, so this fork injects the same behaviour at boot
# instead and leaves those files alone.
#
# to_prepare (not an eager one-shot) is required: in development Zeitwerk
# unloads and reloads Family and Account between requests, and anything mixed in
# outside this hook would be dropped on the first reload.
Rails.application.config.to_prepare do
  Family.include(Family::BitgetConnectable)
  Account.extend(Account::BitgetCreatable)
end
