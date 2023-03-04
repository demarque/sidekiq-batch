require_relative 'extension/job'

module Sidekiq
  class Batch
    module Middleware
      class ClientMiddleware
        include Sidekiq::ClientMiddleware

        def call(_worker, msg, _queue, _redis_pool = nil)
          if (batch = Thread.current[:batch])&.adding_jobs
            msg['bid'] = batch.bid
            batch.register_new_job(msg['jid'])
          end

          yield
        end
      end

      class ServerMiddleware
        include Sidekiq::ServerMiddleware

        def call(_worker, msg, _queue)
          if (bid = msg['bid'])
            # for a job to have access to its batch when running
            Thread.current[:batch] = batch = Sidekiq::Batch.new(bid)
            begin
              yield
              batch.on_job_processed(:successful, msg['jid'])
            rescue
              batch.on_job_processed(:failed, msg['jid'])
              raise
            ensure
              Thread.current[:batch] = nil
            end
          else
            yield
          end
        end
      end

      def self.configure
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add Sidekiq::Batch::Middleware::ClientMiddleware
          end
        end

        Sidekiq.configure_server do |config|
          config.client_middleware do |chain|
            chain.add Sidekiq::Batch::Middleware::ClientMiddleware
          end
          config.server_middleware do |chain|
            chain.add Sidekiq::Batch::Middleware::ServerMiddleware
          end
        end

        Sidekiq::Worker.send(:include, Sidekiq::Batch::Extension::Job)
      end
    end
  end
end
