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

    attr_accessor :adding_jobs, :callback_queue
    attr_reader :bid, :created_at
    attr_writer :parent

    def initialize(existing_bid = nil, parent_bid = nil)
      @bid = existing_bid || SecureRandom.urlsafe_base64(10)
      @new_batch = !existing_bid
      @created_at = Time.now.utc.to_f if @new_batch
      @parent_bid = parent_bid
      @bidkey = "BID-#{@bid}"
      @job_count = 0
      @callbacks = {}
    end

    def valid?
      valid = Sidekiq.redis { |r| r.exists("invalidated-bid-#{bid}") }.zero?
      parent_batch = parent

      valid && (!parent_batch || parent_batch.valid?)
    end

    def key
      @bidkey
    end

    def parent_bid
      @parent_bid ||= Sidekiq.redis { |r| r.hget(key, 'parent_bid') }
    end

    def parent
      return @parent if defined?(@parent)

      @parent = self.class.new(parent_bid) if parent_bid
    end

    # Save the custom callback method to run in redis,
    # so it can be called when the jobs are completed
    # Callbacks are only persisted in redis once the jobs have been added.
    # This allows callbacks computed with knowledge of the jobs that were enqueued.
    # Example: streaming a set of records to add to the job batch and extracting data for the callbacks
    #   like the last record ID, or the number of records, without extra queries.
    def on(event, callback, options = {})
      return unless %w[success complete].include?(event.to_s)

      @callbacks[callback_key_for(event)] = JSON.unparse({ callback: callback, opts: options })
    end

    # Adds jobs to the batch.
    # The jobs are immediately pushed to Redis and can be processed while other jobs are being added.
    # To prevent triggering callbacks while still adding jobs, the batch is flagged as "unready"
    # for the duration on the block. Callbacks aren't triggered until the batch becomes ready.
    def jobs
      raise NoBlockGivenError unless block_given?

      # The batch can be nested into another one
      self.parent = Thread.current[:batch]

      begin
        if @new_batch
          register_batch
        else
          pending, _ = open_existing_batch
        end

        # Prevent adding jobs to an existing batch having its callbacks already triggered,
        # which should be the case when there isn't anymore pending jobs.
        raise "Callbacks already triggered for batch #{bid}" if pending&.zero?

        self.adding_jobs = true
        # set the current batch, so that enqueued jobs can be linked to this batch
        Thread.current[:batch] = self
        yield
      ensure
        self.adding_jobs = false
        Thread.current[:batch] = parent
      end

      if @new_batch && @job_count.zero?
        # Nothing to do, it's just an empty batch
        clean
      else
        _ready, pending, children_pending, _ = mark_batch_as_ready(@job_count, set_callbacks: @new_batch)
        # Batch could have already drained all of its jobs (processing can be faster than enqueuing).
        # Because the batch was unready during this period, no callback was triggered by `on_job_processed`,
        # so callbacks are triggered now.
        enqueue_callbacks(:complete) if pending.zero? && children_pending.zero?
      end

      @job_count
    rescue
      clean
      raise
    ensure
      @job_count = 0
    end

    # For now, just tracking the number of jobs (lighter on memory)
    def register_new_job(_jid)
      @job_count += 1
    end

    # Cancel the batch, by flagging it as invalidated
    # Jobs inside the batch must check their own validity with Worker#valid_within_batch?
    def invalidate_all
      Sidekiq.redis { |r| r.setex("invalidated-bid-#{bid}", BID_EXPIRE_TTL, 1) }
    end

    # Called right after sidekiq processed a job of the batch
    # Pending job count is updated and complete callback is triggered
    # if there is no more pending jobs or children to process.
    # Complete callback always run before success callback,
    # as it has the responsibility of triggering the success callback.
    def on_job_processed(job_state, jid)
      ready, pending, children_pending, _ = Sidekiq.redis do |r|
        r.multi do |multi|
          multi.hget(key, 'ready')
          multi.hincrby(key, 'pending', -1)
          multi.hincrby(key, 'children_pending', 0)
          multi.hincrby(key, 'failed', 1) if job_state != :successful
          multi.expire(key, BID_EXPIRE_TTL)
        end
      end

      Sidekiq.logger.info("done: #{jid} in batch #{@bid}")

      enqueue_callbacks(:complete) if ready.to_i == 1 && pending.zero? && children_pending.zero?
    end

    def enqueue_callbacks(event)
      callbacks, queue, parent_bid = Sidekiq.redis do |r|
        r.multi do |multi|
          multi.smembers(callback_key_for(event))
          multi.hget(key, 'callback_queue')
          multi.hget(key, 'parent_bid')
        end
      end

      raise "Missing callback queue for #{bid}" if queue.nil? || queue.empty?

      # For the callback chain to work properly, we need to enqueue
      # callback worker for all events, even without custom callbacks defined.
      Sidekiq::Client.push_bulk(
        'class' => Sidekiq::Batch::Callback::Job,
        'queue' => queue,
        'args' => build_args_for_callbacks(callbacks, event, parent_bid)
      )
    end

    def clean
      Sidekiq.redis do |r|
        r.del(key, "#{key}-callbacks-complete", "#{key}-callbacks-success")
      end
    end

    protected

    # Keep track of the number of children a batch has
    def increment_children(redis)
      redis.hincrby(key, 'children_total', 1)
      redis.hincrby(key, 'children_pending', 1)
      redis.expire(key, BID_EXPIRE_TTL)
    end

    private

    def register_batch
      Sidekiq.redis do |r|
        r.multi do |multi|
          multi.hset(key, 'callback_queue', callback_queue, 'created_at', @created_at, 'ready', 0)
          if parent
            multi.hset(key, 'parent_bid', parent.bid.to_s)
            parent.increment_children(multi)
          end
          multi.expire(key, BID_EXPIRE_TTL)
        end
      end
    end

    def open_existing_batch
      Sidekiq.redis do |r|
        r.multi do |multi|
          multi.hincrby(key, 'pending', 0)
          multi.hset(key, 'ready', 0)
        end
      end
    end

    def mark_batch_as_ready(job_count, set_callbacks: true)
      Sidekiq.redis do |r|
        r.multi do |multi|
          multi.hset(key, 'ready', 1)
          multi.hincrby(key, 'pending', job_count)
          multi.hincrby(key, 'children_pending', 0)
          multi.hincrby(key, 'total', job_count)
          multi.expire(key, BID_EXPIRE_TTL)
          register_callbacks(multi) if set_callbacks
        end
      end
    end

    def register_callbacks(redis)
      @callbacks.each do |key, callback|
        redis.sadd(key, [callback])
        redis.expire(key, BID_EXPIRE_TTL)
      end
    end

    def callback_key_for(event)
      "#{key}-callbacks-#{event}"
    end

    # Callback::Job will not be enqueue without proper args,
    # so force args even without custom callbacks.
    def build_args_for_callbacks(callbacks, event, parent_bid)
      callbacks = ['{}'] if callbacks.empty? # JSON parsable

      callbacks.map do |jcb|
        cb = Sidekiq.load_json(jcb)
        [cb['callback'].to_s, event.to_s, cb['opts'], @bid, parent_bid]
      end
    end
  end
end
