require 'spec_helper'

class TestWorker
  include Sidekiq::Worker
  def perform
  end
end

describe Sidekiq::Batch do
  it 'has a version number' do
    expect(Sidekiq::Batch::VERSION).not_to be nil
  end

  describe '#initialize' do
    subject { described_class }

    it 'creates bid when called without it' do
      expect(subject.new.bid).not_to be_nil
    end

    it 'reuses bid when called with it' do
      batch = subject.new('dayPO5KxuRXXxw')
      expect(batch.bid).to eq('dayPO5KxuRXXxw')
    end
  end

  describe '#callback_queue' do
    let(:callback_queue) { 'custom_queue' }
    before { subject.callback_queue = callback_queue }

    it 'sets callback_queue' do
      expect(subject.callback_queue).to eq(callback_queue)
    end
  end

  describe '#jobs' do
    it 'throws error if no block given' do
      expect { subject.jobs }.to raise_error Sidekiq::Batch::NoBlockGivenError
    end

    it 'sets Thread.current bid' do
      batch = Sidekiq::Batch.new
      batch.jobs do
        expect(Thread.current[:batch]).to eq(batch)
      end
    end
  end

  describe '#invalidate_all' do
    class InvalidatableJob
      include Sidekiq::Worker

      def perform
        was_performed if valid_within_batch?
      end

      def was_performed; end
    end

    it 'marks batch in redis as invalidated' do
      batch = Sidekiq::Batch.new
      job = InvalidatableJob.new
      allow(job).to receive(:was_performed)
      Thread.current[:batch] = batch

      batch.invalidate_all
      batch.jobs { job.perform }

      expect(job).not_to have_received(:was_performed)
      Thread.current[:batch] = nil
    end

    context 'nested batches' do
      let(:batch_parent) { Sidekiq::Batch.new }
      let(:batch_child_1) { Sidekiq::Batch.new }
      let(:batch_child_2) { Sidekiq::Batch.new }
      let(:job_of_parent) { InvalidatableJob.new }
      let(:job_of_child_1) { InvalidatableJob.new }
      let(:job_of_child_2) { InvalidatableJob.new }

      context 'with parent batch is marked as invalidated' do
        let(:batch_parent) { Sidekiq::Batch.new }

        it 'invalidates all jobs' do
          expect(job_of_parent).not_to receive(:was_performed)
          expect(job_of_child_1).not_to receive(:was_performed)
          expect(job_of_child_2).not_to receive(:was_performed)

          batch_parent.invalidate_all
          batch_parent.jobs do
            [
              job_of_parent.perform,
              batch_child_1.jobs do
                [
                  job_of_child_1.perform,
                  batch_child_2.jobs { job_of_child_2.perform }
                ]
              end
            ]
          end
        end
      end

      context 'with a child batch marked as invalidated' do
        it 'invalidates only requested batch' do
          expect(job_of_parent).to receive(:was_performed)
          expect(job_of_child_1).to receive(:was_performed)
          expect(job_of_child_2).not_to receive(:was_performed)

          batch_child_2.invalidate_all
          batch_parent.jobs do
            [
              job_of_parent.perform,
              batch_child_1.jobs do
                [
                  job_of_child_1.perform,
                  batch_child_2.jobs { job_of_child_2.perform }
                ]
              end
            ]
          end
        end
      end
    end
  end

  describe '#process_failed_job' do
    let(:batch) { Sidekiq::Batch.new.tap { _1.callback_queue = 'default' } }
    let(:bid) { batch.bid }
    let(:jid) { 'ABCD' }
    before { Sidekiq.redis { |r| r.hset("BID-#{bid}", 'pending', 1, 'ready', 1, 'callback_queue', batch.callback_queue) } }

    context 'complete' do
      let(:failed_jid) { 'xxx' }

      it 'tries to call complete callback' do
        expect(batch).to receive(:enqueue_callbacks).with(:complete)
        batch.on_job_processed(:failed, failed_jid)
      end

      it 'add job to failed list' do
        batch.on_job_processed(:failed, 'failed-job-id')
        batch.on_job_processed(:failed, failed_jid)
        failed = Sidekiq.redis { |r| r.hget(batch.key, 'failed') }.to_i
        expect(failed).to eq(2)
      end
    end
  end

  describe '#process_successful_job' do
    let(:batch) { Sidekiq::Batch.new.tap { _1.callback_queue = 'default' } }
    let(:bid) { batch.bid }
    let(:jid) { 'ABCD' }
    before { Sidekiq.redis { |r| r.hset("BID-#{bid}", 'pending', 1, 'ready', 1, 'callback_queue', batch.callback_queue) } }

    context 'complete' do
      before { batch.on(:complete, Object) }
      # before { batch.register_new_job(bid) }
      before { batch.jobs do TestWorker.perform_async end }
      before { batch.on_job_processed(:failed, 'failed-job-id') }

      it 'tries to call complete callback' do
        expect(batch).to receive(:enqueue_callbacks).with(:complete)
        batch.on_job_processed(:successful, 'failed-job-id')
      end
    end

    context 'success' do
      before { batch.on(:complete, Object) }
      it 'tries to call complete callback' do
        expect(batch).to receive(:enqueue_callbacks).with(:complete)
        batch.on_job_processed(:successful, jid)
      end

      it 'cleanups redis key' do
        batch.on_job_processed(:successful, jid)
        expect(Sidekiq.redis { |r| r.get("BID-#{bid}-pending") }.to_i).to eq(0)
      end
    end
  end

  describe '#register_new_job' do
    let(:bid) { 'BID' }
    let(:batch) { Sidekiq::Batch.new.tap { _1.callback_queue = 'default' } }

    it 'increments pending' do
      batch.jobs { TestWorker.perform_async }
      pending = Sidekiq.redis { |r| r.hget("BID-#{batch.bid}", 'pending') }
      expect(pending).to eq('1')
    end

    it 'increments total' do
      batch.jobs { TestWorker.perform_async }
      total = Sidekiq.redis { |r| r.hget("BID-#{batch.bid}", 'total') }
      expect(total).to eq('1')
    end
  end

  describe '#enqueue_callbacks' do
    let(:callback) { double('callback') }
    let(:event) { 'complete' }

    context 'when already called' do
      it 'returns and does not enqueue callbacks' do
        batch = Sidekiq::Batch.new
        batch.callback_queue = 'default'
        batch.on(event, SampleCallback)
        Sidekiq.redis { |r| r.hset(batch.key, 'callback_queue', batch.callback_queue); batch.send(:register_callbacks, r) }

        expect(Sidekiq::Client).not_to receive(:push)
        batch.enqueue_callbacks(event)
      end
    end

    context 'when not yet called' do
      context 'when there is no callback' do
        it 'it returns' do
          batch = Sidekiq::Batch.new
          batch.callback_queue = 'default'
          Sidekiq.redis { |r| r.hset(batch.key, 'callback_queue', batch.callback_queue) }

          expect(Sidekiq::Client).not_to receive(:push)
          batch.enqueue_callbacks(event)
        end
      end

      context 'when callback defined' do
        let(:opts) { { 'a' => 'b' } }

        it 'calls it passing options' do
          batch = Sidekiq::Batch.new
          batch.callback_queue = 'default'
          batch.on(event, SampleCallback, opts)
          Sidekiq.redis { |r| r.hset(batch.key, 'callback_queue', batch.callback_queue); batch.send(:register_callbacks, r) }

          expect(Sidekiq::Client).to receive(:push_bulk).with(
            'class' => Sidekiq::Batch::Callback::Job,
            'args' => [['SampleCallback', event, opts, batch.bid, nil]],
            'queue' => 'default'
          )
          batch.enqueue_callbacks(event)
        end
      end
    end
  end
end
