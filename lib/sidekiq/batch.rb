require 'securerandom'
require 'sidekiq'

require 'sidekiq/batch/callback'
require 'sidekiq/batch/middleware'
require 'sidekiq/batch/status'
require 'sidekiq/batch/version'

module Sidekiq
  class Batch
    class NoBlockGivenError < StandardError; end

    BID_EXPIRE_TTL = 30 * 24 * 3600 # 30 days

    attr_reader :bid, :description, :callback_queue, :created_at

    def initialize(existing_bid = nil)
      @bid = existing_bid || SecureRandom.urlsafe_base64(10)
      @new_batch = !existing_bid
      @created_at = Time.now.utc.to_f if @new_batch
      @bidkey = "BID-#{@bid}"
      @ready_to_queue = []
    end

    def description=(description)
      @description = description
      persist_bid_attr('description', description)
    end

    def callback_queue=(callback_queue)
      @callback_queue = callback_queue
      persist_bid_attr('callback_queue', callback_queue)
    end

    # Save the custom callback method to run in redis,
    # so it can be called when the jobs are completed
    def on(event, callback, options = {})
      return unless %w[success complete].include?(event.to_s)

      callback_key = callback_key_for(event)
      Sidekiq.redis do |r|
        r.multi do
          r.sadd(callback_key, JSON.unparse({ callback: callback, opts: options }))
          r.expire(callback_key, BID_EXPIRE_TTL)
        end
      end
    end

    def jobs
      raise NoBlockGivenError unless block_given?

      # The batch can be nested into another one
      parent = Thread.current[:current_batch]
      parent_bid = parent&.bid

      if @new_batch
        Sidekiq.redis do |r|
          r.multi do
            register_batch(parent_bid, r)
            # Only register a new batch as child
            increment_parent_children(parent_bid, r) if parent_bid
          end
        end
      end

      @ready_to_queue = []

      begin
        # set the current batch, so that enqueued jobs can be linked to this batch
        Thread.current[:current_batch] = self
        yield
      ensure
        Thread.current[:current_batch] = parent
      end

      @ready_to_queue
    end

    def register_new_job(jid)
      @ready_to_queue << jid

      Sidekiq.redis do |r|
        r.multi do
          r.hincrby(@bidkey, 'pending', 1)
          r.hincrby(@bidkey, 'total', 1)
          r.expire(@bidkey, BID_EXPIRE_TTL)

          r.sadd("#{@bidkey}-jids", jid)
          r.expire("#{@bidkey}-jids", BID_EXPIRE_TTL)
        end
      end
    end

    # Cancel the batch, by flagging it as invalidated
    # Jobs inside the batch must check their own validity with Worker#valid_within_batch?
    def invalidate_all
      Sidekiq.redis { |r| r.setex("invalidated-bid-#{bid}", BID_EXPIRE_TTL, 1) }
    end

    def parent_bid
      @parent_bid ||= Sidekiq.redis { |r| r.hget(@bidkey, 'parent_bid') }
    end

    def parent
      self.class.new(parent_bid) if parent_bid
    end

    def valid?
      valid = !Sidekiq.redis { |r| r.exists("invalidated-bid-#{bid}") }
      parent_batch = parent

      valid && (!parent_batch || parent_batch.valid?)
    end

    # Called right after sidekiq procesed a job of the batch
    # Pending job count is updated and complete callback is triggered
    # if there is no more pending jobs or children to process.
    # Complete callback always run before success callback,
    # as it has the responsability of triggering the success callback.
    def process_job(job_state, jid)
      pending, children_pending = Sidekiq.redis do |r|
        r.multi do
          r.hincrby(@bidkey, 'pending', -1)
          r.hincrby(@bidkey, 'children_pending', 0)
          r.expire(@bidkey, BID_EXPIRE_TTL)

          if job_state == :successful
            r.srem("#{@bidkey}-failed", jid)
          else
            r.sadd("#{@bidkey}-failed", jid)
            r.expire("#{@bidkey}-failed", BID_EXPIRE_TTL)
          end

          r.srem("#{@bidkey}-jids", jid)
        end
      end

      Sidekiq.logger.info "done: #{jid} in batch #{@bid}"

      enqueue_callbacks(:complete) if pending.zero? && children_pending.zero?
    end

    def enqueue_callbacks(event)
      callbacks, queue, parent_bid = Sidekiq.redis do |r|
        r.multi do
          r.smembers(callback_key_for(event))
          r.hget(@bidkey, 'callback_queue')
          r.hget(@bidkey, 'parent_bid')
        end
      end

      # For the callback chain to work properly, we need to enqueue
      # callback worker for all events, even without custom callbacks defined.
      Sidekiq::Client.push_bulk(
        'class' => Sidekiq::Batch::Callback::Worker,
        'queue' => queue || Sidekiq::Batch::Callback::Worker::DEFAULT_QUEUE,
        'args' => build_args_for_callbacks(callbacks, event, parent_bid)
      )
    end

    private

    def persist_bid_attr(attribute, value)
      Sidekiq.redis do |r|
        r.multi do
          r.hset(@bidkey, attribute, value)
          r.expire(@bidkey, BID_EXPIRE_TTL)
        end
      end
    end

    def register_batch(parent_bid, redis)
      redis.hset(@bidkey, 'created_at', @created_at)
      redis.hset(@bidkey, 'parent_bid', parent_bid.to_s) if parent_bid
      redis.expire(@bidkey, BID_EXPIRE_TTL)
    end

    # Keep track of the number of children a batch has
    def increment_parent_children(parent_bid, redis)
      redis.hincrby("BID-#{parent_bid}", 'children_total', 1)
      redis.hincrby("BID-#{parent_bid}", 'children_pending', 1)
      redis.expire("BID-#{parent_bid}", BID_EXPIRE_TTL)
    end

    def callback_key_for(event)
      "#{@bidkey}-callbacks-#{event}"
    end

    # Callback::Worker will not be enqueue without proper args,
    # so force args even without custom callbacks.
    def build_args_for_callbacks(callbacks, event, parent_bid)
      callbacks = ['{}'] if callbacks.empty? # JSON parsable

      callbacks.reduce([]) do |memo, jcb|
        cb = Sidekiq.load_json(jcb)
        memo << [cb['callback'], event, cb['opts'], @bid, parent_bid]
      end
    end
  end
end
