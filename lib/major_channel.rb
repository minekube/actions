# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "uri"

module MajorChannel
  REPOSITORY = "minekube/actions"
  DEFAULT_BRANCH = "main"
  TAG = "v1"
  SHA_PATTERN = /\A[0-9a-f]{40}\z/.freeze
  DECISIVE_REVIEW_STATES = %w[APPROVED CHANGES_REQUESTED DISMISSED].freeze
  TRUSTED_PERMISSIONS = %w[admin write].freeze

  class SafetyError < StandardError; end
  class ApiError < StandardError; end
  class CommandError < StandardError; end

  Inputs = Struct.new(
    :event_name,
    :event_action,
    :repository,
    :ref,
    :sha,
    :default_branch,
    :pull_number,
    :pull_request_merged,
    :pull_request_merge_sha,
    :pull_request_head_sha,
    :pull_request_base_ref,
    keyword_init: true
  ) do
    def self.from_env(environment)
      new(
        event_name: environment.fetch("GITHUB_EVENT_NAME"),
        event_action: environment.fetch("GITHUB_EVENT_ACTION"),
        repository: environment.fetch("GITHUB_REPOSITORY"),
        ref: environment.fetch("GITHUB_REF"),
        sha: environment.fetch("GITHUB_SHA"),
        default_branch: environment.fetch("DEFAULT_BRANCH"),
        pull_number: environment.fetch("PULL_REQUEST_NUMBER"),
        pull_request_merged: environment.fetch("PULL_REQUEST_MERGED"),
        pull_request_merge_sha: environment.fetch("PULL_REQUEST_MERGE_SHA"),
        pull_request_head_sha: environment.fetch("PULL_REQUEST_HEAD_SHA"),
        pull_request_base_ref: environment.fetch("PULL_REQUEST_BASE_REF")
      )
    end
  end

  class Advance
    def initialize(inputs:, git:, github:)
      @inputs = inputs
      @git = git
      @github = github
    end

    def call
      validate_context!
      validate_checked_out_commit!
      validate_merged_pull_request!
      validate_current_approval!

      current = tag_sha(@github.tag_ref(TAG))
      return :already_current if current == @inputs.sha

      fetched = @git.fetch_tag(TAG)
      raise SafetyError, "remote #{TAG} changed while fetching" unless fetched == current

      validate_fast_forward!(current)

      rechecked = tag_sha(@github.tag_ref(TAG))
      raise SafetyError, "remote #{TAG} changed before update" unless rechecked == current

      @github.update_tag(TAG, @inputs.sha, force: true)

      actual = tag_sha(@github.tag_ref(TAG))
      raise SafetyError, "remote #{TAG} post-write value did not match the checked-out SHA" unless actual == @inputs.sha

      :advanced
    end

    private

    def validate_context!
      raise SafetyError, "event must be pull_request" unless @inputs.event_name == "pull_request"
      raise SafetyError, "pull request action must be closed" unless @inputs.event_action == "closed"
      raise SafetyError, "repository must be #{REPOSITORY}" unless @inputs.repository == REPOSITORY
      raise SafetyError, "default branch must be #{DEFAULT_BRANCH}" unless @inputs.default_branch == DEFAULT_BRANCH
      raise SafetyError, "ref must be refs/heads/#{DEFAULT_BRANCH}" unless @inputs.ref == "refs/heads/#{DEFAULT_BRANCH}"
      raise SafetyError, "event SHA must be a commit SHA" unless sha?(@inputs.sha)
      raise SafetyError, "pull request number must be positive" unless @inputs.pull_number.match?(/\A[1-9]\d*\z/)
      raise SafetyError, "pull request event must be merged" unless @inputs.pull_request_merged == "true"
      raise SafetyError, "pull request merge SHA must match the event SHA" unless @inputs.pull_request_merge_sha == @inputs.sha
      raise SafetyError, "pull request head must be a commit SHA" unless sha?(@inputs.pull_request_head_sha)
      raise SafetyError, "pull request base must be #{DEFAULT_BRANCH}" unless @inputs.pull_request_base_ref == DEFAULT_BRANCH
    end

    def validate_checked_out_commit!
      raise SafetyError, "checked-out commit does not match the event SHA" unless @git.head_sha == @inputs.sha
    end

    def validate_merged_pull_request!
      pull_request = @github.pull_request(@inputs.pull_number)
      accepted = pull_request["number"] == @inputs.pull_number.to_i &&
        pull_request["state"] == "closed" &&
        pull_request["merged_at"] &&
        pull_request["merge_commit_sha"] == @inputs.sha &&
        pull_request.dig("head", "sha") == @inputs.pull_request_head_sha &&
        pull_request.dig("base", "ref") == DEFAULT_BRANCH &&
        pull_request.dig("base", "repo", "full_name") == REPOSITORY
      raise SafetyError, "event does not match the merged pull request targeting #{DEFAULT_BRANCH}" unless accepted
    end

    def validate_current_approval!
      current_reviews = @github.pull_request_reviews(@inputs.pull_number)
        .select { |review| DECISIVE_REVIEW_STATES.include?(review["state"]) && review.dig("user", "login") }
        .group_by { |review| review.dig("user", "login") }
        .values
        .map { |reviews| reviews.max_by { |review| review.fetch("id") } }

      accepted = current_reviews.any? do |review|
        next false unless review["state"] == "APPROVED" && review["commit_id"] == @inputs.pull_request_head_sha

        permission = @github.collaborator_permission(review.dig("user", "login")).fetch("permission")
        TRUSTED_PERMISSIONS.include?(permission)
      end
      raise SafetyError, "merged pull request lacks a current trusted approval for its final head" unless accepted
    end

    def validate_fast_forward!(current)
      if @git.ancestor?(@inputs.sha, current)
        raise SafetyError, "refusing backward #{TAG} movement"
      end
      return if @git.ancestor?(current, @inputs.sha)

      raise SafetyError, "refusing divergent #{TAG} movement"
    end

    def tag_sha(reference)
      object = reference.fetch("object")
      sha = object.fetch("sha")
      raise SafetyError, "remote #{TAG} must be a lightweight commit tag" unless object.fetch("type") == "commit" && sha?(sha)

      sha
    rescue KeyError
      raise SafetyError, "remote #{TAG} response was incomplete"
    end

    def sha?(value)
      value.is_a?(String) && value.match?(SHA_PATTERN)
    end
  end

  class Git
    def head_sha
      run!("git", "rev-parse", "HEAD")
    end

    def fetch_tag(tag)
      run!("git", "fetch", "--no-tags", "origin", "refs/tags/#{tag}")
      run!("git", "rev-parse", "FETCH_HEAD^{commit}")
    end

    def ancestor?(from, to)
      _output, error, status = Open3.capture3("git", "merge-base", "--is-ancestor", from, to)
      return true if status.success?
      return false if status.exitstatus == 1

      raise CommandError, "git merge-base failed: #{error.strip}"
    end

    private

    def run!(*command)
      output, error, status = Open3.capture3(*command)
      raise CommandError, "#{command.first} command failed: #{error.strip}" unless status.success?

      output.strip
    end
  end

  class GitHub
    def initialize(token:, repository: REPOSITORY)
      @token = token
      @repository = repository
    end

    def pull_request(number)
      request(Net::HTTP::Get, "/repos/#{@repository}/pulls/#{number}")
    end

    def pull_request_reviews(number)
      request_pages("/repos/#{@repository}/pulls/#{number}/reviews")
    end

    def collaborator_permission(login)
      encoded_login = URI.encode_www_form_component(login)
      request(Net::HTTP::Get, "/repos/#{@repository}/collaborators/#{encoded_login}/permission")
    end

    def tag_ref(tag)
      request(Net::HTTP::Get, "/repos/#{@repository}/git/ref/tags/#{tag}")
    end

    def update_tag(tag, sha, force:)
      request(Net::HTTP::Patch, "/repos/#{@repository}/git/refs/tags/#{tag}", sha: sha, force: force)
    end

    private

    def request_pages(path)
      page = 1
      values = []
      loop do
        batch = request(Net::HTTP::Get, "#{path}?per_page=100&page=#{page}")
        raise ApiError, "GitHub API returned an unexpected paginated response" unless batch.is_a?(Array)

        values.concat(batch)
        return values if batch.length < 100

        page += 1
      end
    end

    def request(request_class, path, payload = nil)
      uri = URI("https://api.github.com#{path}")
      request = request_class.new(uri)
      request["Accept"] = "application/vnd.github+json"
      request["Authorization"] = "Bearer #{@token}"
      request["X-GitHub-Api-Version"] = "2022-11-28"
      request.body = JSON.generate(payload) if payload

      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
      raise ApiError, "GitHub API request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise ApiError, "GitHub API returned invalid JSON"
    end
  end
end
