# frozen_string_literal: true

# Read-only. Answers "which of my securities are actually being priced?", which
# the UI only hints at per-holding: holdings/show.html.erb hides the market-data
# block for an offline security, so the only signal is a missing panel and there
# is no list view at all.
#
#   bin/rails fork:securities:status          # everything you hold
#   bin/rails fork:securities:status[all]     # every security, held or not
def flag_for(row)
  # Crypto resolves through the exchange's own SecurityResolver fallback, which
  # marks it offline on purpose: Bitget/Kraken supply the valuation, so there is
  # nothing for a market data provider to fetch. Not a problem, never flag it.
  return "" if row[:ticker].to_s.start_with?("CRYPTO:")
  return "" unless row[:held]

  # A held security with no prices hides silently: the daily importer skips
  # offline securities entirely, so it never tries and nothing reaches the logs.
  if row[:status] == :offline then "OFFLINE - never priced"
  elsif row[:prices].zero?    then "NO PRICES"
  elsif row[:mic].blank?      then "no exchange set"
  elsif row[:status] == :stale then "recent fetch failures"
  else ""
  end
end

namespace :fork do
  namespace :securities do
    desc "List securities with their pricing status (arg: all to include unheld)"
    task :status, [ :scope ] => :environment do |_t, args|
      include_unheld = args[:scope].to_s == "all"

      provider = Provider::Registry.for_concept(:securities).get_provider(:yahoo_finance)
      puts "yahoo_finance health: #{provider&.health_status.inspect} (treated as down: #{Security.provider_down?(provider)})"
      puts

      held_ids = Holding.distinct.pluck(:security_id).to_set
      rows = Security.where.not(kind: "cash").order(:ticker).filter_map do |security|
        held = held_ids.include?(security.id)
        next unless held || include_unheld

        latest = security.prices.order(:date).last

        {
          ticker: security.ticker,
          mic: security.exchange_operating_mic.to_s,
          held: held,
          status: security.provider_status,
          offline_reason: security.offline_reason.to_s,
          fails: security.failed_fetch_count.to_i,
          prices: security.prices.count,
          latest: latest&.date&.to_s.to_s
        }
      end

      if rows.empty?
        puts "No securities found."
        next
      end

      format = "%-14s %-6s %-5s %-20s %-6s %-7s %-11s %s"
      puts format % %w[TICKER MIC HELD STATUS FAILS PRICES LATEST FLAG]
      puts "-" * 88

      rows.each do |row|
        puts format % [
          row[:ticker], row[:mic], (row[:held] ? "yes" : "-"),
          [ row[:status], row[:offline_reason].presence ].compact.join(":"),
          row[:fails], row[:prices], row[:latest].presence || "-", flag_for(row)
        ]
      end

      problems = rows.count { |row| flag_for(row).present? }

      puts
      puts "#{rows.size} shown, #{problems} with a pricing problem."
      puts "Crypto (CRYPTO:*) is offline by design - those holdings are valued by the"
      puts "exchange provider directly, so they are not counted above."
    end
  end
end
