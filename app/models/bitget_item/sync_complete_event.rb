# frozen_string_literal: true

class BitgetItem::SyncCompleteEvent
  def initialize(bitget_item)
    raise ArgumentError, "bitget_item is required" unless bitget_item.respond_to?(:family) && bitget_item.respond_to?(:id)

    @bitget_item = bitget_item
  end

  def broadcast
    Turbo::StreamsChannel.broadcast_replace_to(
      @bitget_item.family,
      target: ActionView::RecordIdentifier.dom_id(@bitget_item),
      partial: "bitget_items/bitget_item",
      locals: { bitget_item: @bitget_item }
    )
  rescue StandardError => e
    Rails.logger.warn("BitgetItem::SyncCompleteEvent failed for #{@bitget_item.id}: #{e.class}")
  end
end
