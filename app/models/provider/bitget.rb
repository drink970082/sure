# frozen_string_literal: true

# Read-only client for the Bitget Unified Trading Account (UTA, v3) REST API.
#
# Modelled on Provider::Kraken, with four deliberate differences:
#
#   1. Auth carries a passphrase in addition to the key/secret pair.
#   2. The signature covers timestamp + METHOD + path + query + body, and the
#      query must be sorted by key. See #canonical_query.
#   3. Success is signalled by a "00000" body code, not by an empty error array.
#   4. Coin symbols are already plain (BTC, USDT), so there is no asset-name
#      normalizer the way Kraken needs one for XXBT/ZUSD.
class Provider::Bitget
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class PermissionError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  BASE_URL = "https://api.bitget.com"
  SUCCESS_CODE = "00000"

  # Bitget serves at most 90 days of history, and rejects a single query whose
  # startTime/endTime span exceeds 30 days. Callers window their requests using
  # these; see BitgetItem::Importer.
  MAX_HISTORY_DAYS = 90
  MAX_WINDOW_DAYS = 30

  # Bitget's own SDK sends query values unencoded and signs the same string, so
  # any escaping here would break the signature. Every value we send is a coin
  # code, category, millisecond timestamp, or numeric cursor - all URL-safe.
  # Reject anything else rather than silently signing a string we can't send.
  UNSAFE_QUERY_VALUE = /[^A-Za-z0-9_.\-]/

  ACCOUNT_ASSETS_PATH = "/api/v3/account/assets"
  FUNDING_ASSETS_PATH = "/api/v3/account/funding-assets"
  FINANCIAL_RECORDS_PATH = "/api/v3/account/financial-records"
  FILLS_PATH = "/api/v3/trade/fills"

  # Earn for a unified account. The classic v2 Earn endpoint
  # (/api/v2/earn/savings/assets) is NOT usable here: once an account is
  # upgraded to UTA, Bitget rejects the whole authenticated v2 surface with
  # 40085 "You are in Unified Account mode, and the Classic Account API is not
  # supported at this time". Public v2 market data still works.
  ELITE_ASSETS_PATH = "/api/v3/earn/elite-assets"

  # Public, unauthenticated. One call returns every spot pair, which is how
  # funding balances get a USD value - that endpoint reports none.
  SPOT_TICKERS_PATH = "/api/v2/spot/market/tickers"

  MAX_PAGE_SIZE = 100

  base_uri BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret, :passphrase

  def initialize(api_key:, api_secret:, passphrase:, timestamp_generator: nil)
    @api_key = api_key # pipelock:ignore user-supplied Bitget credential kept in memory for signed requests
    @api_secret = api_secret # pipelock:ignore user-supplied Bitget credential kept in memory for signed requests
    @passphrase = passphrase # pipelock:ignore user-supplied Bitget credential kept in memory for signed requests
    @timestamp_generator = timestamp_generator || -> { (Time.now.to_f * 1000).round.to_s }
  end

  # Account equity plus the per-coin asset list. Doubles as the credential
  # check: it is the cheapest authenticated call Bitget exposes.
  #
  # Covers the unified trading account only. Money parked in the funding
  # account or in Earn is invisible here - see #get_funding_assets and
  # #get_savings_assets.
  def get_account_assets
    private_get(ACCOUNT_ASSETS_PATH)
  end

  # The funding account, i.e. the pot coins sit in between transfers. Returns a
  # bare array of {coin, available, frozen, balance} with no USD valuation.
  def get_funding_assets(coin: nil)
    private_get(FUNDING_ASSETS_PATH, { "coin" => coin })
  end

  # On-chain Elite Earn positions (BGUSD / BGBTC / BGSOL). Unlike the funding
  # account this one does report a USD equivalent, so it needs no ticker lookup.
  #
  # This is the only Earn surface a unified account can read. Classic Savings
  # positions - if any remain - are not reachable through the API at all while
  # the account is in UTA mode.
  def get_elite_assets
    private_get(ELITE_ASSETS_PATH)
  end

  # Every spot pair's last price, unauthenticated. Used to value coins that the
  # authenticated endpoints report without a usdValue.
  def get_spot_tickers
    public_get(SPOT_TICKERS_PATH)
  end

  # Deposits, withdrawals, fees and rewards. `category` is mandatory.
  def get_financial_records(category: "SPOT", coin: nil, start_time: nil, end_time: nil, cursor: nil, limit: MAX_PAGE_SIZE)
    private_get(FINANCIAL_RECORDS_PATH, {
      "category" => category,
      "coin" => coin,
      "startTime" => start_time,
      "endTime" => end_time,
      "cursor" => cursor,
      "limit" => limit
    })
  end

  # Executed trades. `category` is mandatory.
  def get_fills(category: "SPOT", symbol: nil, start_time: nil, end_time: nil, cursor: nil, limit: MAX_PAGE_SIZE)
    private_get(FILLS_PATH, {
      "category" => category,
      "symbol" => symbol,
      "startTime" => start_time,
      "endTime" => end_time,
      "cursor" => cursor,
      "limit" => limit
    })
  end

  private

    attr_reader :timestamp_generator

    def private_get(path, params = {})
      query = canonical_query(params)
      timestamp = timestamp_generator.call.to_s

      response = self.class.get(
        "#{path}#{query}",
        headers: auth_headers(timestamp, "GET", path, query)
      )

      handle_response(response)
    end

    def public_get(path, params = {})
      handle_response(self.class.get("#{path}#{canonical_query(params)}"))
    end

    # Builds the "?a=1&b=2" suffix that is both signed and sent. Keys are sorted
    # ascending because Bitget verifies the signature against the sorted form;
    # an unsorted query returns a signature error, not a helpful message.
    def canonical_query(params)
      pairs = params.filter_map do |key, value|
        next if value.nil?

        string_value = value.to_s
        next if string_value.empty?

        if string_value.match?(UNSAFE_QUERY_VALUE)
          raise ArgumentError, "Bitget query value for #{key} contains characters that cannot be signed unencoded"
        end

        [ key.to_s, string_value ]
      end

      return "" if pairs.empty?

      "?" + pairs.sort_by(&:first).map { |key, value| "#{key}=#{value}" }.join("&")
    end

    def auth_headers(timestamp, method, path, query, body = "")
      {
        "ACCESS-KEY" => api_key,
        "ACCESS-SIGN" => sign(timestamp, method, path, query, body),
        "ACCESS-PASSPHRASE" => passphrase,
        "ACCESS-TIMESTAMP" => timestamp,
        "locale" => "en-US",
        "Content-Type" => "application/json"
      }
    end

    def sign(timestamp, method, path, query, body)
      prehash = "#{timestamp}#{method.to_s.upcase}#{path}#{query}#{body}"
      Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", api_secret.to_s, prehash))
    end

    def handle_response(response)
      raise RateLimitError, "Bitget rate limit exceeded" if response.code == 429

      parsed = response.parsed_response

      unless response.code.between?(200, 299)
        # Bitget puts the real reason in the body even on a 4xx (for example
        # 40085 "You are in Unified Account mode, and the Classic Account API is
        # not supported"). Reporting only the HTTP status throws that away and
        # makes the failure undiagnosable from the sync error alone.
        if parsed.is_a?(Hash) && parsed["code"].present?
          raise classified_error(parsed["code"].to_s, parsed["msg"].to_s)
        end

        raise ApiError, "Bitget API request failed: #{response.code}"
      end

      unless parsed.is_a?(Hash)
        raise ApiError, "Malformed Bitget API response"
      end

      code = parsed["code"].to_s
      raise ApiError, "Malformed Bitget API response: missing code" if code.empty?
      raise classified_error(code, parsed["msg"].to_s) unless code == SUCCESS_CODE

      parsed["data"]
    end

    def classified_error(code, message)
      detail = "#{message.presence || 'Bitget API error'} (code #{code})"

      case
      when message.match?(/sign|signature|apikey|api key|passphrase|access[_ -]?key|secret/i)
        AuthenticationError.new(detail)
      when message.match?(/permission|not authorized|unauthorized|\bip\b/i)
        PermissionError.new(detail)
      when message.match?(/too many requests|rate limit|frequency|request too frequent/i)
        RateLimitError.new(detail)
      else
        ApiError.new(detail)
      end
    end
end
