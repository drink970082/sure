# frozen_string_literal: true

require "test_helper"
require "uri"

class Provider::BitgetAdapterTest < ActiveSupport::TestCase
  setup do
    bitget_items(:requires_update).update!(scheduled_for_deletion: true)
  end

  test "supports Crypto accounts only" do
    assert_includes Provider::BitgetAdapter.supported_account_types, "Crypto"
    assert_not_includes Provider::BitgetAdapter.supported_account_types, "Depository"
  end

  test "returns fallback connection config when no credentials exist yet" do
    configs = Provider::BitgetAdapter.connection_configs(family: families(:empty))

    assert_equal 1, configs.length
    assert_equal "bitget", configs.first[:key]
    assert_equal I18n.t("bitget_items.provider_connection.default_name"), configs.first[:name]
    assert configs.first[:can_connect]
  end

  test "returns one connection config per credentialed bitget item" do
    family = families(:dylan_family)
    first_item = bitget_items(:one)
    second_item = BitgetItem.create!(
      family: family,
      name: "Business Bitget",
      api_key: "second_bitget_key",
      api_secret: "second_bitget_secret",
      passphrase: "second_bitget_passphrase"
    )

    configs = Provider::BitgetAdapter.connection_configs(family: family)

    assert_equal [ "bitget_#{second_item.id}", "bitget_#{first_item.id}" ], configs.map { |config| config[:key] }

    new_account_uri = URI.parse(configs.first[:new_account_path].call("Crypto", "/accounts"))
    assert_equal "/bitget_items/select_accounts", new_account_uri.path
    assert_includes new_account_uri.query, "bitget_item_id=#{second_item.id}"

    existing_account_uri = URI.parse(configs.first[:existing_account_path].call(accounts(:crypto).id))
    assert_equal "/bitget_items/select_existing_account", existing_account_uri.path
    assert_includes existing_account_uri.query, "bitget_item_id=#{second_item.id}"
  end

  test "connection configs ignore items whose passphrase was cleared" do
    family = families(:dylan_family)
    blank_item = BitgetItem.create!(
      family: family,
      name: "Blank Bitget",
      api_key: "temporary_key",
      api_secret: "temporary_secret",
      passphrase: "temporary_passphrase"
    )
    blank_item.update_columns(passphrase: "   ")

    configs = Provider::BitgetAdapter.connection_configs(family: family)

    assert_equal [ "bitget_#{bitget_items(:one).id}" ], configs.map { |config| config[:key] }
  end

  test "build_provider returns nil without a family or without items" do
    assert_nil Provider::BitgetAdapter.build_provider(family: nil)
    assert_nil Provider::BitgetAdapter.build_provider(family: families(:empty))
  end

  test "build_provider returns a Bitget provider when exactly one item is credentialed" do
    provider = Provider::BitgetAdapter.build_provider(family: families(:dylan_family))

    assert_instance_of Provider::Bitget, provider
  end

  test "build_provider requires an explicit item when several are credentialed" do
    family = families(:dylan_family)
    BitgetItem.create!(
      family: family,
      name: "Second Bitget",
      api_key: "second_bitget_key",
      api_secret: "second_bitget_secret",
      passphrase: "second_bitget_passphrase"
    )

    assert_nil Provider::BitgetAdapter.build_provider(family: family)
  end

  test "build_provider uses the explicit item's credentials, whitespace stripped" do
    family = families(:dylan_family)
    second_item = BitgetItem.create!(
      family: family,
      name: "Second Bitget",
      api_key: " second_bitget_key \n",
      api_secret: " second_bitget_secret \n",
      passphrase: " second_bitget_passphrase \n"
    )

    provider = Provider::BitgetAdapter.build_provider(family: family, bitget_item_id: second_item.id)

    assert_instance_of Provider::Bitget, provider
    assert_equal "second_bitget_key", provider.api_key
    assert_equal "second_bitget_secret", provider.api_secret
    assert_equal "second_bitget_passphrase", provider.passphrase
  end

  test "build_provider refuses bitget items outside the family" do
    other_item = BitgetItem.create!(
      family: families(:empty),
      name: "Other Bitget",
      api_key: "other_bitget_key",
      api_secret: "other_bitget_secret",
      passphrase: "other_bitget_passphrase"
    )

    assert_nil Provider::BitgetAdapter.build_provider(family: families(:dylan_family), bitget_item_id: other_item.id)
  end
end
