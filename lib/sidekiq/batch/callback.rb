module Sidekiq
  class Batch
    module Callback
      class Job
        include Sidekiq::Job

        def perform(clazz, event, opts, bid, parent_bid)
          return unless %w[success complete].include?(event)

          Sidekiq::Context.with(bid: bid) { Sidekiq.logger.info("running #{event} callback for batch #{bid}") }

          # Custom callback
          clazz, method = clazz.to_s.split('#')
          if clazz
            method ||= "on_#{event}"
            Object.const_get(clazz).new.send(method, Sidekiq::Batch::Status.new(bid), opts)
          end

          # Trigger after custom callback has run, to manage next callbacks and parent batch
          send(event.to_sym, Batch.new(bid, parent_bid))
        end

        def complete(batch)
          failed = Sidekiq.redis { |r| r.hget(batch.key, 'failed') }.to_i

          if failed.zero?
            batch.enqueue_callbacks(:success)
          else
            # nothing more to do with the batch
            batch.clean
          end

          parent_batch = batch.parent

          return unless parent_batch

          parent_ready, parent_pending, parent_children_pending = Sidekiq.redis do |r|
            r.multi do |multi|
              multi.hget(parent_batch.key, 'ready')
              multi.hincrby(parent_batch.key, 'pending', 0)
              if failed.zero?
                # let the success callback remove the current batch from its parent pending children
                multi.hincrby(parent_batch.key, 'children_pending', 0)
              else
                multi.hincrby(parent_batch.key, 'children_pending', -1)
                multi.hincrby(parent_batch.key, 'children_failed', 1)
              end
            end
          end

          # The success callback of the current batch could add more jobs to the parent batch,
          # so let it handle its parent callbacks when it runs.
          parent_batch.enqueue_callbacks(:complete) if !failed.zero? && parent_ready.to_i.zero? && parent_pending.zero? && parent_children_pending.zero?
        end

        def success(batch)
          batch.clean

          parent_batch = batch.parent

          return unless parent_batch

          parent_ready, parent_pending, parent_children_pending = Sidekiq.redis do |r|
            r.multi do |multi|
              multi.hget(parent_batch.key, 'ready')
              multi.hincrby(parent_batch.key, 'pending', 0)
              multi.hincrby(parent_batch.key, 'children_pending', -1)
            end
          end

          parent_batch.enqueue_callbacks(:complete) if parent_ready.to_i == 1 && parent_pending.zero? && parent_children_pending.zero?
        end
      end
    end
  end
end
