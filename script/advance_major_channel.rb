#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/major_channel"

begin
  inputs = MajorChannel::Inputs.from_env(ENV)
  github = MajorChannel::GitHub.new(token: ENV.fetch("GITHUB_TOKEN"), repository: inputs.repository)
  result = MajorChannel::Advance.new(inputs: inputs, git: MajorChannel::Git.new, github: github).call
  puts "#{MajorChannel::TAG} #{result.to_s.tr('_', ' ')} at #{inputs.sha}"
rescue MajorChannel::SafetyError, MajorChannel::ApiError, MajorChannel::CommandError, KeyError => error
  warn "major-channel update refused: #{error.message}"
  exit 1
end
