module Sidekiq::Batch::Extension
  module Worker
    def bid
      batch&.bid
    end

    def batch
      Thread.current[:batch]
    end

    # For a job to validate itself
    # For example to implement as an early return at the beginning of a job:
    # class MyJob
    #   def perform
    #     return unless valid_within_batch?
    #     # actual work here
    #   end
    # end
    def valid_within_batch?
      batch.valid?
    end
  end
end
