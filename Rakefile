# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rbconfig"

# The Minitest suite. It boots a real (non-ActiveRecord) Rails app against
# DynamoDB Local, so the endpoint must be reachable at DYNAMODB_ENDPOINT
# (default http://localhost:8000 — run `bin/setup` or `docker compose up -d`).
# Globs only *_test.rb so the standalone smoke scripts below are not double-run.
Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false # aws-sdk / Rails emit many benign warnings under -w
end

desc "Run the standalone end-to-end smoke scripts (Mode A, Mode B, schema discovery)"
task :smoke do
  # Each smoke script boots its own Rails app, so run them as fresh
  # subprocesses (inheriting this process's bundle via RUBYOPT/BUNDLE_*).
  FileList["test/*smoke*.rb"].sort.each do |script|
    puts "\n== #{script} =="
    sh RbConfig.ruby, "-Ilib", "-Itest", script
  end
end

# RuboCop is a development dependency; expose `rake rubocop` but don't gate the
# default task on it (so `rake` stays runnable in a lint-free bundle).
begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError
  # RuboCop not installed in this bundle — skip the task.
end

task default: :test
