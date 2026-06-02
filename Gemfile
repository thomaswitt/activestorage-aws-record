# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# The generic custom Active Storage backend contract this gem targets is not yet
# in a released Rails. Point the Rails framework gems at the local checkout that
# carries the `activestorage-backends` work. The monorepo's framework gems are
# mutually version-locked (e.g. 8.2.0.alpha), so path-reference all of them.
rails_path = File.expand_path('../rails', __dir__)
if Dir.exist?(rails_path)
  %w[
    activesupport activemodel activejob activerecord
    actionview actionpack actioncable actionmailbox actionmailer actiontext
    activestorage railties
  ].each do |framework|
    framework_path = File.join(rails_path, framework)
    gem framework, path: framework_path if Dir.exist?(framework_path)
  end
end

group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
  gem 'debug', require: false
  gem 'rubocop-rails-omakase', require: false
  gem 'rubocop-rake', require: false
end
