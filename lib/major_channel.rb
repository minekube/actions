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

  class SafetyError < StandardError; end
  class ApiError < StandardError; end
  class CommandError < StandardError; end

  Inputs = Struct.new(:event_name, :repository, :ref, :sha, :default_branch, keyword_init: true) do
    def self.from_env(environment)
      new(
        event_name: environment.fetch("GITHUB_EVENT_NAME"),
        repository: environment.fetch("GITHUB_REPOSITORY"),
        ref: environment.fetch("GITHUB_REF"),
        sha: environment.fetch("GITHUB_SHA"),
        default_branch: environment.fetch("DEFAULT_BRANCH")
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

      current = tag_sha(@github.tag_ref(TAG))
      return :already_current if current == @inputs.sha

      fetched = @git.fetch_tag(TAG)
      raise SafetyError, "remote #{TAG} changed while fetching" unless fetched == current

      validate_fast_forward!(current)

      rechecked = tag_sha(@github.tag_ref(TAG))
      raise SafetyError, "remote #{TAG} changed before update" unless rechecked == current

      # GitHub's git-ref API needs force: true to move an existing lightweight tag.
      # The event, PR, test, checkout, and ancestry gates above make this a checked
      # fast-forward channel update rather than an unconstrained force push.
      @github.update_tag(TAG, @inputs.sha, force: true)

      actual = tag_sha(@github.tag_ref(TAG))
      raise SafetyError, "remote #{TAG} post-write value did not match the checked-out SHA" unless actual == @inputs.sha

      :advanced
    end

    private

    def validate_context!
      raise SafetyError, "event must be push" unless @inputs.event_name == "push"
      raise SafetyError, "repository must be #{REPOSITORY}" unless @inputs.repository == REPOSITORY
      raise SafetyError, "default branch must be #{DEFAULT_BRANCH}" unless @inputs.default_branch == DEFAULT_BRANCH
      raise SafetyError, "ref must be refs/heads/#{DEFAULT_BRANCH}" unless @inputs.ref == "refs/heads/#{DEFAULT_BRANCH}"
      raise SafetyError, "event SHA must be a commit SHA" unless @inputs.sha.match?(SHA_PATTERN)
    end

    def validate_checked_out_commit!
      raise SafetyError, "checked-out commit does not match the event SHA" unless @git.head_sha == @inputs.sha
    end

    def validate_merged_pull_request!
      accepted = @github.pull_requests_for_commit(@inputs.sha).any? do |pull_request|
        pull_request["merged_at"] &&
          pull_request.dig("base", "ref") == DEFAULT_BRANCH &&
          pull_request["merge_commit_sha"] == @inputs.sha
      end
      raise SafetyError, "event SHA is not the merge commit of a merged pull request targeting #{DEFAULT_BRANCH}" unless accepted
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
      raise SafetyError, "remote #{TAG} must be a lightweight commit tag" unless object.fetch("type") == "commit" && sha.match?(SHA_PATTERN)

      sha
    rescue KeyError
      raise SafetyError, "remote #{TAG} response was incomplete"
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

    def pull_requests_for_commit(sha)
      request(Net::HTTP::Get, "/repos/#{@repository}/commits/#{sha}/pulls")
    end

    def tag_ref(tag)
      request(Net::HTTP::Get, "/repos/#{@repository}/git/ref/tags/#{tag}")
    end

    def update_tag(tag, sha, force:)
      request(Net::HTTP::Patch, "/repos/#{@repository}/git/refs/tags/#{tag}", sha: sha, force: force)
    end

    private

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
