module Sidekiq
  class Batch
    module Callback
      class Worker
        include Sidekiq::Worker

        DEFAULT_QUEUE = 'default'

        def perform(clazz, event, opts, bid, parent_bid)
          return unless %w[success complete].include?(event)

          # Custom callback
          clazz, method = clazz.to_s.split('#')
          if clazz
            method ||= "on_#{event}"
            Object.const_get(clazz).new.send(method, Sidekiq::Batch::Status.new(bid), opts)
          end

          # Trigger after custom callback has run, to manage next callbacks and parent batch
          send(event.to_sym, bid, parent_bid)
        end

        def complete(bid, parent_bid)
          failed = Sidekiq.redis { |r| r.scard("BID-#{bid}-failed") }

          if failed.zero?
            Batch.new(bid).enqueue_callbacks(:success)
          else
            # nothing more to do with the batch
            clean_redis(bid)
          end

          return unless parent_bid

          parent_pending, parent_children_pending = Sidekiq.redis do |r|
            r.multi do
              r.hincrby("BID-#{parent_bid}", 'pending', 0)
              if failed.zero?
                # let the success callback remove the current batch from its parent pending children
                r.hincrby("BID-#{parent_bid}", 'children_pending', 0)
              else
                r.hincrby("BID-#{parent_bid}", 'children_pending', -1)
                r.hincrby("BID-#{parent_bid}", 'children_failed', 1)
              end
            end
          end

          # The success callback of the current batch could add more jobs to the parent batch,
          # so let it handle its parent callbacks when it runs.
          Batch.new(parent_bid).enqueue_callbacks(:complete) if !failed.zero? && parent_pending.zero? && parent_children_pending.zero?
        end

        def success(bid, parent_bid)
          clean_redis(bid)

          return unless parent_bid

          parent_pending, parent_children_pending = Sidekiq.redis do |r|
            r.multi do
              r.hincrby("BID-#{parent_bid}", 'pending', 0)
              r.hincrby("BID-#{parent_bid}", 'children_pending', -1)
            end
          end

          Batch.new(parent_bid).enqueue_callbacks(:complete) if parent_pending.zero? && parent_children_pending.zero?
        end

        private

        def clean_redis(bid)
          bid_key = "BID-#{bid}"

          Sidekiq.redis do |r|
            r.del(bid_key, "#{bid_key}-callbacks-complete", "#{bid_key}-callbacks-success", "#{bid_key}-failed", "#{bid_key}-jids")
          end
        end
      end
    end
  end
end
