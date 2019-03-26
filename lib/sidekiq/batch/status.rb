module Sidekiq
  class Batch
    class Status
      attr_reader :bid

      def initialize(bid)
        @bid = bid
      end

      def join
        raise 'Not supported'
      end

      def pending
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'pending') }.to_i
      end

      def failures
        Sidekiq.redis { |r| r.scard("BID-#{bid}-failed") }.to_i
      end

      def created_at
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'created_at') }
      end

      def total
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'total') }.to_i
      end

      def parent_bid
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'parent_bid') }
      end

      def failure_info
        Sidekiq.redis { |r| r.smembers("BID-#{bid}-failed") } || []
      end

      def complete?
        pending.zero? && pending_children.zero?
      end

      def pending_children
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'children_pending') }.to_i
      end

      def failed_children
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'children_failed') }.to_i
      end

      def total_children
        Sidekiq.redis { |r| r.hget("BID-#{bid}", 'children_total') }.to_i
      end

      def data
        {
          total: total,
          failures: failures,
          pending: pending,
          created_at: created_at,
          complete: complete?,
          failure_info: failure_info,
          parent_bid: parent_bid,
          total_children: total_children,
          pending_children: pending_children,
          failed_children: failed_children
        }
      end
    end
  end
end
