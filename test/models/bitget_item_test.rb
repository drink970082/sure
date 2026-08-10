# frozen_string_literal: true

require "test_helper"

class BitgetItemTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "requires all three credentials" do
    item = BitgetItem.new(family: @family, name: "Bitget", api_key: "k", api_secret: "s")

    assert_not item.valid?
    assert_includes item.errors.attribute_names, :passphrase
  end

  test "credentials_configured? demands a passphrase" do
    item = BitgetItem.new(family: @family, name: "Bitget", api_key: "k", api_secret: "s", passphrase: " ")

    assert_not item.credentials_configured?

    item.passphrase = "p"
    assert item.credentials_configured?
  end

  test "strips whitespace pasted around credentials" do
    item = BitgetItem.create!(family: @family, name: "Bitget", api_key: " k ", api_secret: " s ", passphrase: " p ")

    assert_equal "k", item.api_key
    assert_equal "s", item.api_secret
    assert_equal "p", item.passphrase
  end

  test "bitget_provider is nil until credentials are complete" do
    item = BitgetItem.new(family: @family, name: "Bitget", api_key: "k", api_secret: "s")

    assert_nil item.bitget_provider

    item.passphrase = "p"
    assert_instance_of Provider::Bitget, item.bitget_provider
  end

  test "credentials_configured scope excludes items missing a passphrase" do
    complete = BitgetItem.create!(family: @family, name: "Complete", api_key: "k", api_secret: "s", passphrase: "p")
    incomplete = BitgetItem.create!(family: @family, name: "Incomplete", api_key: "k", api_secret: "s", passphrase: "p")
    incomplete.update_columns(passphrase: nil)

    configured = BitgetItem.credentials_configured
    assert_includes configured, complete
    assert_not_includes configured, incomplete
  end

  test "family gains bitget associations through the fork initializer" do
    assert_respond_to @family, :bitget_items
    assert @family.can_connect_bitget?
  end

  test "set_bitget_institution_defaults! fills institution metadata" do
    item = BitgetItem.create!(family: @family, name: "Bitget", api_key: "k", api_secret: "s", passphrase: "p")
    item.set_bitget_institution_defaults!

    assert_equal "Bitget", item.institution_name
    assert_equal "bitget.com", item.institution_domain
    assert_equal "Bitget", item.institution_display_name
  end
end
