# frozen_string_literal: true

class Provider::BitgetAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  Provider::Factory.register("BitgetAccount", self)

  def self.supported_account_types
    %w[Crypto]
  end

  def self.connection_configs(family:)
    return [] unless family.can_connect_bitget?

    bitget_items = family.bitget_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return [ connection_config_for(nil) ] if bitget_items.empty?

    bitget_items.map { |bitget_item| connection_config_for(bitget_item) }
  end

  def self.build_provider(family: nil, bitget_item_id: nil)
    return nil unless family.present?

    bitget_item = resolve_bitget_item(family, bitget_item_id)
    return nil unless bitget_item&.credentials_configured?

    bitget_item.bitget_provider
  end

  def provider_name
    "bitget"
  end

  def sync_path
    return unless item

    Rails.application.routes.url_helpers.sync_bitget_item_path(item)
  end

  def item
    provider_account.bitget_item
  end

  def can_delete_holdings?
    false
  end

  def institution_domain
    institution_metadata_value("domain")
  end

  def institution_name
    institution_metadata_value("name")
  end

  def institution_url
    institution_metadata_value("url")
  end

  def institution_color
    institution_metadata_value("color")
  end

  def self.connection_config_for(bitget_item)
    path_params = ->(extra = {}) do
      bitget_item.present? ? extra.merge(bitget_item_id: bitget_item.id) : extra
    end

    {
      key: bitget_item.present? ? "bitget_#{bitget_item.id}" : "bitget",
      name: bitget_item.present? ? I18n.t("bitget_items.provider_connection.name", name: bitget_item.name) : I18n.t("bitget_items.provider_connection.default_name"),
      description: bitget_item.present? ? I18n.t("bitget_items.provider_connection.description", name: bitget_item.name) : I18n.t("bitget_items.provider_connection.default_description"),
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_bitget_items_path(
          path_params.call(accountable_type: accountable_type, return_to: return_to)
        )
      },
      existing_account_path: ->(account_id) {
        Rails.application.routes.url_helpers.select_existing_account_bitget_items_path(
          path_params.call(account_id: account_id)
        )
      }
    }
  end
  private_class_method :connection_config_for

  def self.resolve_bitget_item(family, bitget_item_id)
    if bitget_item_id.present?
      item = family.bitget_items.active.credentials_configured.find_by(id: bitget_item_id)
      return item if item&.credentials_configured?

      return nil
    end

    credentialed_items = family.bitget_items.active.credentials_configured.ordered.select(&:credentials_configured?)
    return credentialed_items.first if credentialed_items.one?

    nil
  end
  private_class_method :resolve_bitget_item

  private

    def institution_metadata_value(key)
      metadata = provider_account.institution_metadata || {}
      metadata[key] || item&.public_send("institution_#{key}")
    end
end
