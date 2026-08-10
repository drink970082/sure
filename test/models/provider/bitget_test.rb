# frozen_string_literal: true

require "test_helper"
require "base64"

class Provider::BitgetTest < ActiveSupport::TestCase
  # Inputs taken from Bitget's own signing example (UTA Quick Start): the same
  # timestamp, method, request path and sorted query. The expected signature is
  # computed with the documented algorithm over a fixed test secret, so a change
  # to how the prehash is assembled fails this test.
  SAMPLE_TIMESTAMP = "1685013478665"
  SAMPLE_SECRET = "bitget_test_secret"
  SAMPLE_PREHASH = "1685013478665GET/api/v3/account/fee-rate?category=SPOT&symbol=BTCUSDT"
  SAMPLE_SIGNATURE = "oPlCM8dHlJBDA4wvNJ02w0MDSR21zyxClXWOaviEMgE="
  NO_QUERY_SIGNATURE = "vrR9HBkiJMeIEcEgTlJqnOxZQer6vHzEDCcaYu45A7A="

  setup do
    @provider = Provider::Bitget.new(
      api_key: "test_key",
      api_secret: SAMPLE_SECRET,
      passphrase: "test_passphrase",
      timestamp_generator: -> { SAMPLE_TIMESTAMP }
    )
  end

  test "sign matches the documented prehash layout" do
    query = @provider.send(:canonical_query, { "symbol" => "BTCUSDT", "category" => "SPOT" })

    assert_equal "?category=SPOT&symbol=BTCUSDT", query
    assert_equal(
      SAMPLE_SIGNATURE,
      @provider.send(:sign, SAMPLE_TIMESTAMP, "GET", "/api/v3/account/fee-rate", query, "")
    )
  end

  test "sign omits the query segment entirely when there are no params" do
    assert_equal(
      NO_QUERY_SIGNATURE,
      @provider.send(:sign, SAMPLE_TIMESTAMP, "GET", "/api/v3/account/assets", "", "")
    )
  end

  test "canonical query sorts keys ascending regardless of insertion order" do
    query = @provider.send(:canonical_query, {
      "startTime" => "2", "category" => "SPOT", "limit" => "100", "cursor" => "9"
    })

    assert_equal "?category=SPOT&cursor=9&limit=100&startTime=2", query
  end

  test "canonical query drops nil and blank values" do
    query = @provider.send(:canonical_query, { "category" => "SPOT", "coin" => nil, "symbol" => "" })

    assert_equal "?category=SPOT", query
  end

  test "canonical query refuses values that cannot be sent unencoded" do
    assert_raises(ArgumentError) do
      @provider.send(:canonical_query, { "coin" => "BTC&category=OTHER" })
    end
  end

  test "auth headers carry key, passphrase, timestamp and signature" do
    headers = @provider.send(:auth_headers, SAMPLE_TIMESTAMP, "GET", "/api/v3/account/assets", "")

    assert_equal "test_key", headers["ACCESS-KEY"]
    assert_equal "test_passphrase", headers["ACCESS-PASSPHRASE"]
    assert_equal SAMPLE_TIMESTAMP, headers["ACCESS-TIMESTAMP"]
    assert_equal NO_QUERY_SIGNATURE, headers["ACCESS-SIGN"]
    assert_equal 32, Base64.strict_decode64(headers["ACCESS-SIGN"]).bytesize
  end

  test "get_account_assets requests the assets endpoint with no query" do
    payload = { "accountEquity" => "11.13", "assets" => [] }
    response = mock_httparty_response(200, { "code" => "00000", "msg" => "success", "data" => payload })

    Provider::Bitget.expects(:get)
      .with("/api/v3/account/assets", has_entries(headers: has_entries("ACCESS-KEY" => "test_key")))
      .returns(response)

    assert_equal payload, @provider.get_account_assets
  end

  test "get_fills sends a sorted query string that matches the signed path" do
    response = mock_httparty_response(200, { "code" => "00000", "data" => { "list" => [], "cursor" => nil } })

    Provider::Bitget.expects(:get)
      .with("/api/v3/trade/fills?category=SPOT&endTime=2000&limit=100&startTime=1000", anything)
      .returns(response)

    @provider.get_fills(start_time: "1000", end_time: "2000")
  end

  test "get_financial_records forwards category, window and cursor" do
    response = mock_httparty_response(200, { "code" => "00000", "data" => { "list" => [] } })

    Provider::Bitget.expects(:get)
      .with("/api/v3/account/financial-records?category=SPOT&cursor=42&endTime=2000&limit=100&startTime=1000", anything)
      .returns(response)

    @provider.get_financial_records(start_time: "1000", end_time: "2000", cursor: "42")
  end

  test "handle response returns data on the success code" do
    response = mock_httparty_response(200, { "code" => "00000", "data" => { "ok" => true } })

    assert_equal({ "ok" => true }, @provider.send(:handle_response, response))
  end

  test "handle response raises api error for non 2xx" do
    response = mock_httparty_response(500, { "code" => "50001" })

    assert_raises(Provider::Bitget::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response raises rate limit error on 429 before parsing" do
    response = mock_httparty_response(429, nil)

    assert_raises(Provider::Bitget::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response rejects non-envelope payloads" do
    response = mock_httparty_response(200, [ "not", "an", "envelope" ])

    error = assert_raises(Provider::Bitget::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed Bitget API response", error.message
  end

  test "handle response requires a code" do
    response = mock_httparty_response(200, { "data" => {} })

    error = assert_raises(Provider::Bitget::ApiError) do
      @provider.send(:handle_response, response)
    end

    assert_equal "Malformed Bitget API response: missing code", error.message
  end

  test "handle response maps signature failures to authentication errors" do
    response = mock_httparty_response(200, { "code" => "40009", "msg" => "sign signature error" })

    assert_raises(Provider::Bitget::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps permission failures" do
    response = mock_httparty_response(200, { "code" => "40014", "msg" => "Incorrect permissions" })

    assert_raises(Provider::Bitget::PermissionError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps ip allowlist rejections to permission errors" do
    response = mock_httparty_response(200, { "code" => "40018", "msg" => "Invalid IP" })

    assert_raises(Provider::Bitget::PermissionError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response maps throttling to rate limit errors" do
    response = mock_httparty_response(200, { "code" => "429", "msg" => "request too frequent" })

    assert_raises(Provider::Bitget::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle response falls back to a generic api error" do
    error = assert_raises(Provider::Bitget::ApiError) do
      @provider.send(:handle_response, mock_httparty_response(200, { "code" => "50067", "msg" => "service busy" }))
    end

    assert_includes error.message, "service busy"
    assert_includes error.message, "50067"
  end

  private

    def mock_httparty_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
