#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/major_channel"

class MajorChannelContractTest < Minitest::Test
  REPOSITORY = "minekube/actions"
  SHA = "a" * 40
  PRIOR_SHA = "b" * 40
  DIVERGENT_SHA = "c" * 40

  FakeGit = Struct.new(:head, :fetched_tag, :ancestries, keyword_init: true) do
    attr_reader :fetches

    def head_sha
      head
    end

    def fetch_tag(tag)
      (@fetches ||= []) << tag
      fetched_tag
    end

    def ancestor?(from, to)
      ancestries.fetch([from, to], false)
    end
  end

  class FakeGitHub
    attr_reader :updates

    def initialize(refs:, pull_requests: [], update_error: nil)
      @refs = refs.dup
      @pull_requests = pull_requests
      @update_error = update_error
      @updates = []
    end

    def pull_requests_for_commit(_sha)
      @pull_requests
    end

    def tag_ref(_tag)
      value = @refs.shift
      raise MajorChannel::ApiError, "missing tag response" unless value

      value
    end

    def update_tag(tag, sha, force:)
      raise @update_error if @update_error

      @updates << [tag, sha, force]
    end
  end

  def test_advances_an_ancestor_tag_only_for_the_matching_merged_pull_request
    git = git_with_ancestor
    github = github_with_refs(PRIOR_SHA, PRIOR_SHA, SHA)

    result = advance(git: git, github: github)

    assert_equal :advanced, result
    assert_equal ["v1"], git.fetches
    assert_equal [["v1", SHA, true]], github.updates
  end

  def test_refuses_a_direct_push_without_a_merged_pull_request_for_the_exact_sha
    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA, pull_requests: []))
    end

    assert_match(/merged pull request/, error.message)
  end

  def test_refuses_a_merged_pull_request_when_its_merge_sha_is_not_the_event_sha
    pull_request = merged_pull_request.merge("merge_commit_sha" => PRIOR_SHA)

    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA, pull_requests: [pull_request]))
    end

    assert_match(/merged pull request/, error.message)
  end

  def test_refuses_the_wrong_repository_or_ref
    repository_error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), repository: "fork/actions")
    end
    assert_match(/repository/, repository_error.message)

    ref_error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), ref: "refs/heads/feature")
    end
    assert_match(/ref/, ref_error.message)
  end

  def test_requires_a_push_to_the_main_default_branch_and_the_exact_checked_out_sha
    [
      { event_name: "pull_request", message: /event/ },
      { default_branch: "trunk", message: /default branch/ },
      { checked_out_sha: PRIOR_SHA, message: /checked-out/ }
    ].each do |override|
      error = assert_raises(MajorChannel::SafetyError) do
        advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), **override)
      end

      assert_match(override.fetch(:message), error.message)
    end
  end

  def test_noops_when_v1_already_matches_the_checked_out_sha
    github = github_with_refs(SHA)

    assert_equal :already_current, advance(git: git_with_ancestor, github: github)
    assert_empty github.updates
  end

  def test_refuses_backward_tag_movement
    git = FakeGit.new(
      head: SHA,
      fetched_tag: PRIOR_SHA,
      ancestries: {
        [SHA, PRIOR_SHA] => true
      }
    )

    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git, github: github_with_refs(PRIOR_SHA))
    end

    assert_match(/backward/, error.message)
  end

  def test_refuses_divergent_tag_movement
    git = FakeGit.new(head: SHA, fetched_tag: DIVERGENT_SHA, ancestries: {})

    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git, github: github_with_refs(DIVERGENT_SHA))
    end

    assert_match(/divergent/, error.message)
  end

  def test_surfaces_an_api_failure_without_claiming_an_update
    github = github_with_refs(PRIOR_SHA, PRIOR_SHA, update_error: MajorChannel::ApiError.new("403 forbidden"))

    error = assert_raises(MajorChannel::ApiError) do
      advance(git: git_with_ancestor, github: github)
    end

    assert_match(/403 forbidden/, error.message)
  end

  def test_fails_closed_when_the_remote_post_write_value_does_not_match
    github = github_with_refs(PRIOR_SHA, PRIOR_SHA, DIVERGENT_SHA)

    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github)
    end

    assert_match(/post-write/, error.message)
    assert_equal [["v1", SHA, true]], github.updates
  end

  def test_workflow_is_review_gated_and_pins_its_checkout_action
    workflow = YAML.safe_load(File.read(File.expand_path("../.github/workflows/advance-v1.yml", __dir__)), aliases: false)
    source = File.read(File.expand_path("../.github/workflows/advance-v1.yml", __dir__))

    assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
    assert_includes source, "pull_request:"
    assert_includes source, "push:\n    branches:\n      - main"
    assert_includes source, "github.event_name == 'push'"
    assert_includes source, "github.event.repository.default_branch == 'main'"
    assert_includes source, "cancel-in-progress: false"
    assert_includes source, "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
    refute_match(/workflow_dispatch|schedule|secrets:/, source)

    advance = workflow.fetch("jobs").fetch("advance")
    assert_equal({ "contents" => "write", "pull-requests" => "read" }, advance.fetch("permissions"))
    assert_equal "major-channel-v1", advance.fetch("concurrency").fetch("group")
    assert_includes advance.fetch("steps").map { |step| step["name"] }, "Run repository contracts before tag update"
  end

  private

  def advance(git:, github:, repository: REPOSITORY, ref: "refs/heads/main", event_name: "push", default_branch: "main", checked_out_sha: nil, **_ignored)
    git.head = checked_out_sha if checked_out_sha
    MajorChannel::Advance.new(
      inputs: MajorChannel::Inputs.new(
        event_name: event_name,
        repository: repository,
        ref: ref,
        sha: SHA,
        default_branch: default_branch
      ),
      git: git,
      github: github
    ).call
  end

  def git_with_ancestor
    FakeGit.new(
      head: SHA,
      fetched_tag: PRIOR_SHA,
      ancestries: {
        [PRIOR_SHA, SHA] => true
      }
    )
  end

  def github_with_refs(*refs, pull_requests: [merged_pull_request], update_error: nil)
    FakeGitHub.new(
      refs: refs.map { |sha| { "object" => { "type" => "commit", "sha" => sha } } },
      pull_requests: pull_requests,
      update_error: update_error
    )
  end

  def merged_pull_request
    {
      "merged_at" => "2026-07-19T00:00:00Z",
      "merge_commit_sha" => SHA,
      "base" => { "ref" => "main" }
    }
  end
end
