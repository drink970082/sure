# frozen_string_literal: true

module BitgetItem::Provided
  extend ActiveSupport::Concern

  def bitget_provider
    return nil unless credentials_configured?

    Provider::Bitget.new(
      api_key: api_key.to_s.strip,
      api_secret: api_secret.to_s.strip,
      passphrase: passphrase.to_s.strip
    )
  end
end
