# Sidekiq::Batch
Based on https://codeclimate.com/github/breamware/sidekiq-batch

Simple Sidekiq Batch Job implementation.

## Requirements
Ruby >= 3

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'sidekiq-batch'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install sidekiq-batch

In your Sidekiq initializer:
```ruby
Sidekiq::Batch::Middleware.configure
```

## Usage

Sidekiq Batch is almost drop-in replacement for the API from Sidekiq PRO. See https://github.com/mperham/sidekiq/wiki/Batches for global usage.

Example
```ruby
batch = Sidekiq::Batch.new
batch.callback_queue = "callback-queue" # mandatory
# Callbacks can be defined before adding jobs
batch.on(:complete, CallbackClass, data: [1, 2], extra: 'som extra')

last_row_data = nil
batch.jobs do
  # Parse rows in a streaming fashion
  CSV.foreach(...) do |row|
    last_row_data = row[4] # extract some data
    # Processing can be completed before the whole CSV is parsed.
    # Callbacks won't be triggered while the `jobs` block isn't completed.
    MyCSVRowJob.perform_async(row)
  end

  # Callbacks can also be defined when adding jobs, inside the `jobs` block.
  # Here it can be computed using parsed CSV data (without having to read it twice or loading it in memory)
  batch.on(:success, CallbackClass, data: last_row_data)
end
```

## Notes on behavior
* Callbacks are run in serial: first the :complete which then calls the :success callback, if conditions are met.
* Both callbacks (:complete and :success) always run for each batch in this order, even if there is no custom callback methods to perform. This is to ensure proper callback chaining and consistency with nested batches (child batch callback run before parent callbacks).
* Callbacks handle parent child counts and the trigger of the parent's callbacks, in a recursive way.
* Parent batch only knows of its direct children (only their counts: total, pending, failed). Similarly, a batch only knows about its direct parent.
* Job counts and child counts are batch specific: they aren't propagated through the parents (ie: incrementing job counts in a batch doesn't increment its parent job counts)
* Completion of a batch depends on its own pending jobs and the completion of its children.
* Callbacks are registered only for new batches, when adding jobs is completed.
* Callbacks aren't triggered while jobs are still being added to the batch (batch is considered "unready").
* Only one callback by type is accepted (complete or success).
* For performance and lower memory footprint, only job counts are tracked by the job, not JID.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
