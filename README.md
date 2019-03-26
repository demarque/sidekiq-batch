[gem]: https://rubygems.org/gems/sidekiq-batch
[travis]: https://travis-ci.org/breamware/sidekiq-batch
[codeclimate]: https://codeclimate.com/github/breamware/sidekiq-batch

# Sidekiq::Batch

[![Join the chat at https://gitter.im/breamware/sidekiq-batch](https://badges.gitter.im/breamware/sidekiq-batch.svg)](https://gitter.im/breamware/sidekiq-batch?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

[![Gem Version](https://badge.fury.io/rb/sidekiq-batch.svg)][gem]
[![Build Status](https://travis-ci.org/breamware/sidekiq-batch.svg?branch=master)][travis]
[![Code Climate](https://codeclimate.com/github/breamware/sidekiq-batch/badges/gpa.svg)][codeclimate]
[![Code Climate](https://codeclimate.com/github/breamware/sidekiq-batch/badges/coverage.svg)][codeclimate]
[![Code Climate](https://codeclimate.com/github/breamware/sidekiq-batch/badges/issue_count.svg)][codeclimate]

Simple Sidekiq Batch Job implementation.

## Requirements
Ruby >= 2.3

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'sidekiq-batch'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install sidekiq-batch

## Usage

Sidekiq Batch is drop-in replacement for the API from Sidekiq PRO. See https://github.com/mperham/sidekiq/wiki/Batches for usage.

## Notes on behavior
* Callbacks are run in serial: first the :complete which then calls the :success callback, if conditions are met.
* Both callbacks (:complete and :success) always run for each batch in this order, even if there is no custom callback methods to perform. This is to ensure proper callback chaining and consistency with nested batches (child batch callback run before parent callbacks).
* Callbacks handle parent child counts and the trigger of the parent's callbacks, in a recursive way.
* Parent batch only knows of its direct children (only their counts: total, pending, failed). Similarly, a batch only knows about its direct parent.
* Job counts and child counts are batch specific: they aren't propagated through the parents (ie: incrementing job counts in a batch doesn't increment its parent job counts)
* Completion of a batch depends on its own pending jobs and the completion of its children.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/breamware/sidekiq-batch.

## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).
