require_relative 'extension/worker'

module Sidekiq
  class Batch
    module Middleware
      class ClientMiddleware
        def call(_worker, msg, _queue, _redis_pool = nil)
          if (batch = Thread.current[:current_batch])
            msg['bid'] = batch.bid
            batch.register_new_job(msg['jid'])
          end
          yield
        end
      end

      class ServerMiddleware
        def call(_worker, msg, _queue)
          if (bid = msg['bid'])
            batch = Sidekiq::Batch.new(bid)
            begin
              # for a job to have access to its batch when running
              Thread.current[:batch] = batch
              yield
              Thread.current[:batch] = nil
              batch.process_job(:successful, msg['jid'])
            rescue
              batch.process_job(:failed, msg['jid'])
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
        Sidekiq::Worker.send(:include, Sidekiq::Batch::Extension::Worker)
      end
    end
  end
end

Sidekiq::Batch::Middleware.configure
