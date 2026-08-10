# frozen_string_literal: true

require "test_helper"

class BitgetItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = bitget_items(:one)
    bitget_items(:requires_update).update!(scheduled_for_deletion: true)
    @second_item = BitgetItem.create!(
      family: @family,
      name: "Business Bitget",
      api_key: "second_bitget_key",
      api_secret: "second_bitget_secret",
      passphrase: "second_bitget_passphrase"
    )
  end

  test "create adds a new bitget connection without overwriting existing credentials" do
    existing_key = @existing_item.api_key
    existing_passphrase = @existing_item.passphrase

    assert_difference "BitgetItem.count", 1 do
      post bitget_items_url, params: {
        bitget_item: {
          name: "Joint Bitget",
          api_key: "joint_bitget_key",
          api_secret: "joint_bitget_secret",
          passphrase: "joint_bitget_passphrase"
        }
      }
    end

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal existing_passphrase, @existing_item.passphrase

    created = @family.bitget_items.find_by!(name: "Joint Bitget")
    assert_equal "joint_bitget_key", created.api_key
    assert_equal "joint_bitget_passphrase", created.passphrase
    assert_equal "Bitget", created.institution_name
  end

  test "create rejects a connection with no passphrase" do
    assert_no_difference "BitgetItem.count" do
      post bitget_items_url, params: {
        bitget_item: { name: "No Passphrase", api_key: "k", api_secret: "s" }
      }
    end
  end

  test "update changes only the selected bitget connection" do
    existing_key = @existing_item.api_key

    patch bitget_item_url(@second_item), params: {
      bitget_item: {
        name: "Renamed Business Bitget",
        api_key: "updated_second_key",
        api_secret: "updated_second_secret",
        passphrase: "updated_second_passphrase"
      }
    }

    assert_redirected_to settings_providers_path
    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal "Renamed Business Bitget", @second_item.reload.name
    assert_equal "updated_second_key", @second_item.api_key
    assert_equal "updated_second_passphrase", @second_item.passphrase
  end

  test "update keeps stored credentials when the form fields are left blank" do
    original_key = @second_item.api_key
    original_secret = @second_item.api_secret
    original_passphrase = @second_item.passphrase

    patch bitget_item_url(@second_item), params: {
      bitget_item: { name: "Renamed Only", api_key: "", api_secret: "", passphrase: "" }
    }

    @second_item.reload
    assert_equal "Renamed Only", @second_item.name
    assert_equal original_key, @second_item.api_key
    assert_equal original_secret, @second_item.api_secret
    assert_equal original_passphrase, @second_item.passphrase
  end

  test "destroy schedules the connection for deletion" do
    delete bitget_item_url(@second_item)

    assert_redirected_to settings_providers_path
    assert @second_item.reload.scheduled_for_deletion?
  end

  test "sync enqueues a sync for the connection" do
    post sync_bitget_item_url(@second_item)

    assert_response :redirect
  end

  test "select_accounts redirects to setup for the requested connection" do
    get select_accounts_bitget_items_url(bitget_item_id: @second_item.id)

    assert_redirected_to setup_accounts_bitget_item_path(@second_item)
  end

  test "select_accounts asks which connection when several are credentialed" do
    get select_accounts_bitget_items_url

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("bitget_items.select_accounts.select_connection"), flash[:alert]
  end

  test "complete_account_setup links a bitget account to a new crypto account" do
    bitget_account = @second_item.bitget_accounts.create!(
      name: "Bitget",
      account_id: "combined",
      account_type: "combined",
      currency: "USD",
      current_balance: 500
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_bitget_item_url(@second_item), params: {
        selected_accounts: [ bitget_account.id ]
      }
    end

    assert_redirected_to accounts_path
    assert bitget_account.reload.account_provider.present?
    assert_equal "Crypto", bitget_account.account.accountable_type
  end

  test "complete_account_setup reports when nothing was selected" do
    post complete_account_setup_bitget_item_url(@second_item), params: { selected_accounts: [] }

    assert_redirected_to accounts_path
    assert_equal I18n.t("bitget_items.complete_account_setup.none_selected"), flash[:notice]
  end

  test "cannot access another family's bitget item" do
    other_item = BitgetItem.create!(
      family: families(:empty),
      name: "Other Bitget",
      api_key: "other_key",
      api_secret: "other_secret",
      passphrase: "other_passphrase"
    )

    get setup_accounts_bitget_item_url(other_item)

    assert_response :not_found
  end
end
