#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../lib/major_channel"

class MajorChannelContractTest < Minitest::Test
  REPOSITORY = "minekube/actions"
  SHA = "a" * 40
  HEAD_SHA = "d" * 40
  PRIOR_SHA = "b" * 40
  DIVERGENT_SHA = "c" * 40
  PULL_NUMBER = "42"

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

    def initialize(refs:, pull_request:, reviews:, permissions:, update_error: nil)
      @refs = refs.dup
      @pull_request = pull_request
      @reviews = reviews
      @permissions = permissions
      @update_error = update_error
      @updates = []
    end

    def pull_request(_number)
      @pull_request
    end

    def pull_request_reviews(_number)
      @reviews
    end

    def collaborator_permission(login)
      { "permission" => @permissions.fetch(login, "none") }
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

  def test_advances_an_ancestor_tag_only_for_the_exact_approved_merge_event
    git = git_with_ancestor
    github = github_with_refs(PRIOR_SHA, PRIOR_SHA, SHA)

    result = advance(git: git, github: github)

    assert_equal :advanced, result
    assert_equal ["v1"], git.fetches
    assert_equal [["v1", SHA, true]], github.updates
  end

  def test_refuses_events_other_than_a_merged_pull_request_close
    [
      { event_name: "push", message: /pull_request/ },
      { event_action: "synchronize", message: /closed/ },
      { pull_request_merged: "false", message: /merged/ }
    ].each do |override|
      error = assert_raises(MajorChannel::SafetyError) do
        advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), **override)
      end

      assert_match override.fetch(:message), error.message
    end
  end

  def test_refuses_when_the_event_merge_sha_is_not_the_checked_out_sha
    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), pull_request_merge_sha: PRIOR_SHA)
    end

    assert_match(/merge SHA/, error.message)
  end

  def test_refuses_when_the_refetched_pull_request_does_not_match_the_event
    [
      merged_pull_request.merge("merge_commit_sha" => PRIOR_SHA),
      merged_pull_request.merge("head" => { "sha" => PRIOR_SHA }),
      merged_pull_request.merge("base" => { "ref" => "trunk", "repo" => { "full_name" => REPOSITORY } })
    ].each do |pull_request|
      error = assert_raises(MajorChannel::SafetyError) do
        advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA, pull_request: pull_request))
      end

      assert_match(/merged pull request/, error.message)
    end
  end

  def test_requires_a_current_approval_for_the_final_pull_request_head
    stale = approved_review.merge("commit_id" => PRIOR_SHA)
    superseded = approved_review.merge("id" => 10)
    changes_requested = approved_review.merge("id" => 11, "state" => "CHANGES_REQUESTED")

    [[], [stale], [superseded, changes_requested]].each do |reviews|
      error = assert_raises(MajorChannel::SafetyError) do
        advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA, reviews: reviews))
      end

      assert_match(/current trusted approval/, error.message)
    end
  end

  def test_requires_the_current_approver_to_have_write_permission
    error = assert_raises(MajorChannel::SafetyError) do
      github = github_with_refs(PRIOR_SHA, permissions: { "reviewer" => "read" })
      advance(git: git_with_ancestor, github: github)
    end

    assert_match(/current trusted approval/, error.message)
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

  def test_requires_main_as_the_default_branch_and_the_exact_checked_out_sha
    [
      { default_branch: "trunk", message: /default branch/ },
      { checked_out_sha: PRIOR_SHA, message: /checked-out/ }
    ].each do |override|
      error = assert_raises(MajorChannel::SafetyError) do
        advance(git: git_with_ancestor, github: github_with_refs(PRIOR_SHA), **override)
      end

      assert_match override.fetch(:message), error.message
    end
  end

  def test_noops_without_a_write_when_v1_already_matches_the_merge_sha
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

  def test_reports_a_post_write_mismatch_after_the_update_was_issued
    github = github_with_refs(PRIOR_SHA, PRIOR_SHA, DIVERGENT_SHA)

    error = assert_raises(MajorChannel::SafetyError) do
      advance(git: git_with_ancestor, github: github)
    end

    assert_match(/post-write/, error.message)
    assert_equal [["v1", SHA, true]], github.updates
  end

  def test_workflow_binds_writes_to_the_closed_merge_event_and_pins_actions
    workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
    source = File.read(workflow_path)

    assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
    assert_includes source, "types: [opened, synchronize, reopened, closed]"
    assert_includes source, "github.event.action == 'closed'"
    assert_includes source, "github.event.pull_request.merged == true"
    assert_includes source, "github.event.pull_request.merge_commit_sha == github.sha"
    assert_includes source, "github.event.repository.default_branch == 'main'"
    assert_includes source, "cancel-in-progress: false"
    assert_includes source, "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
    assert_includes source, "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b"
    refute_match(/workflow_dispatch|schedule|secrets:|\n  push:/, source)

    advance_job = workflow.fetch("jobs").fetch("advance")
    assert_equal({ "contents" => "write", "pull-requests" => "read" }, advance_job.fetch("permissions"))
    assert_equal "major-channel-v1", advance_job.fetch("concurrency").fetch("group")
  end

  def test_workflow_keeps_repository_code_and_credentials_out_of_the_write_job
    workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
    validate_steps = workflow.fetch("jobs").fetch("validate").fetch("steps")
    checkout = validate_steps.find { |step| step["name"] == "Checkout exact event commit" }
    advance_steps = workflow.fetch("jobs").fetch("advance").fetch("steps")

    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    assert_includes validate_steps.map { |step| step["name"] }, "Verify exact checked-out SHA"
    assert_includes validate_steps.map { |step| step["name"] }, "Run repository contracts"
    assert_equal ["Advance the major channel"], advance_steps.map { |step| step["name"] }
    refute advance_steps.any? { |step| step.key?("run") || step.fetch("uses", "").include?("checkout") }
  end

  def test_workflow_requires_a_current_final_head_approval_from_a_trusted_reviewer
    source = File.read(workflow_path)

    assert_includes source, "pulls.listReviews"
    assert_includes source, "review.commit_id !== finalHead"
    assert_includes source, 'new Set(["admin", "write"])'
    assert_includes source, "getCollaboratorPermissionLevel"
    assert_includes source, "current trusted approval"
  end

  private

  def workflow_path
    File.expand_path("../.github/workflows/advance-v1.yml", __dir__)
  end

  def advance(git:, github:, repository: REPOSITORY, ref: "refs/heads/main", event_name: "pull_request", event_action: "closed", default_branch: "main", pull_request_merged: "true", pull_request_merge_sha: SHA, pull_request_head_sha: HEAD_SHA, checked_out_sha: nil, **_ignored)
    git.head = checked_out_sha if checked_out_sha
    MajorChannel::Advance.new(
      inputs: MajorChannel::Inputs.new(
        event_name: event_name,
        event_action: event_action,
        repository: repository,
        ref: ref,
        sha: SHA,
        default_branch: default_branch,
        pull_number: PULL_NUMBER,
        pull_request_merged: pull_request_merged,
        pull_request_merge_sha: pull_request_merge_sha,
        pull_request_head_sha: pull_request_head_sha,
        pull_request_base_ref: "main"
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

  def github_with_refs(*refs, pull_request: merged_pull_request, reviews: [approved_review], permissions: { "reviewer" => "write" }, update_error: nil)
    FakeGitHub.new(
      refs: refs.map { |sha| { "object" => { "type" => "commit", "sha" => sha } } },
      pull_request: pull_request,
      reviews: reviews,
      permissions: permissions,
      update_error: update_error
    )
  end

  def merged_pull_request
    {
      "number" => PULL_NUMBER.to_i,
      "state" => "closed",
      "merged_at" => "2026-07-19T00:00:00Z",
      "merge_commit_sha" => SHA,
      "head" => { "sha" => HEAD_SHA },
      "base" => { "ref" => "main", "repo" => { "full_name" => REPOSITORY } }
    }
  end

  def approved_review
    {
      "id" => 1,
      "state" => "APPROVED",
      "commit_id" => HEAD_SHA,
      "user" => { "login" => "reviewer" }
    }
  end
end
