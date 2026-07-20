#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require "yaml"

class MajorChannelContractTest < Minitest::Test
  REPOSITORY = "minekube/actions"
  SHA = "a" * 40
  HEAD_SHA = "d" * 40
  PRIOR_SHA = "b" * 40
  DIVERGENT_SHA = "c" * 40
  PULL_NUMBER = 42

  def test_deployed_script_advances_after_all_guards_pass
    result = run_deployed_script

    assert_nil result.fetch("error")
    assert_equal [
      {
        "owner" => "minekube",
        "repo" => "actions",
        "ref" => "tags/v1",
        "sha" => SHA,
        "force" => true
      }
    ], result.dig("calls", "updates")
    assert_equal 2, result.dig("calls", "reviews").length
    assert_equal 1, result.dig("calls", "comparisons").length
    assert_includes result.fetch("notices"), "v1 advanced to #{SHA}"
  end

  def test_deployed_script_refuses_invalid_event_contexts_without_writes
    cases = [
      ["pull_request event", /pull_request_target\.closed/, ->(scenario) { scenario.dig("context")["eventName"] = "pull_request" }],
      ["opened action", /pull_request_target\.closed/, ->(scenario) { scenario.dig("context", "payload")["action"] = "opened" }],
      ["payload repository", /repository must be/, ->(scenario) { scenario.dig("context", "payload", "repository")["full_name"] = "fork/actions" }],
      ["context repository", /repository must be/, ->(scenario) { scenario.dig("context", "repo")["owner"] = "fork" }],
      ["default branch ref", /ref and default branch/, ->(scenario) { scenario.dig("context")["ref"] = "refs/heads/feature" }],
      ["default branch name", /ref and default branch/, ->(scenario) { scenario.dig("context", "payload", "repository")["default_branch"] = "trunk" }],
      ["event SHA", /merged pull request and commit SHA/, ->(scenario) { scenario.dig("context")["sha"] = "invalid" }],
      ["missing pull request", /merged pull request and commit SHA/, ->(scenario) { scenario.dig("context", "payload")["pull_request"] = nil }],
      ["pull request state", /merged pull request and commit SHA/, ->(scenario) { scenario.dig("context", "payload", "pull_request")["state"] = "open" }],
      ["merged state", /merged pull request and commit SHA/, ->(scenario) { scenario.dig("context", "payload", "pull_request")["merged"] = false }],
      ["merge SHA", /merge SHA must match/, ->(scenario) { scenario.dig("context", "payload", "pull_request")["merge_commit_sha"] = PRIOR_SHA }],
      ["final head SHA", /final head SHA/, ->(scenario) { scenario.dig("context", "payload", "pull_request", "head")["sha"] = "invalid" }],
      ["base branch", /must target/, ->(scenario) { scenario.dig("context", "payload", "pull_request", "base")["ref"] = "trunk" }],
      ["base repository", /must target/, ->(scenario) { scenario.dig("context", "payload", "pull_request", "base", "repo")["full_name"] = "fork/actions" }]
    ]

    cases.each do |name, message, mutate|
      result = run_deployed_script(&mutate)
      assert_match message, result.fetch("error"), name
      assert_empty result.dig("calls", "updateAttempts"), name
    end
  end

  def test_deployed_script_refuses_refetched_pull_request_mismatches
    cases = [
      ["number", /no longer reports/, ->(scenario) { scenario.fetch("pull")["number"] = 43 }],
      ["state", /no longer reports/, ->(scenario) { scenario.fetch("pull")["state"] = "open" }],
      ["merged", /no longer reports/, ->(scenario) { scenario.fetch("pull")["merged"] = false }],
      ["merged timestamp", /no longer reports/, ->(scenario) { scenario.fetch("pull")["merged_at"] = nil }],
      ["merge SHA", /does not match/, ->(scenario) { scenario.fetch("pull")["merge_commit_sha"] = PRIOR_SHA }],
      ["head SHA", /does not match/, ->(scenario) { scenario.dig("pull", "head")["sha"] = PRIOR_SHA }],
      ["base branch", /does not target/, ->(scenario) { scenario.dig("pull", "base")["ref"] = "trunk" }],
      ["base repository", /does not target/, ->(scenario) { scenario.dig("pull", "base", "repo")["full_name"] = "fork/actions" }]
    ]

    cases.each do |name, message, mutate|
      result = run_deployed_script(&mutate)
      assert_match message, result.fetch("error"), name
      assert_empty result.dig("calls", "updateAttempts"), name
    end
  end

  def test_deployed_script_requires_a_current_final_head_approval_from_a_trusted_reviewer
    cases = [
      ["missing", ->(scenario) { scenario["reviewSets"] = [[], []] }],
      ["stale", ->(scenario) { scenario["reviewSets"].flatten.each { |review| review["commit_id"] = PRIOR_SHA } }],
      ["superseded", lambda do |scenario|
        scenario["reviewSets"] = 2.times.map do
          [approved_review.merge("id" => 10), approved_review.merge("id" => 11, "state" => "CHANGES_REQUESTED")]
        end
      end],
      ["dismissed", lambda do |scenario|
        scenario["reviewSets"] = 2.times.map do
          [approved_review.merge("id" => 10), approved_review.merge("id" => 11, "state" => "DISMISSED")]
        end
      end],
      ["untrusted", ->(scenario) { scenario["permissions"]["reviewer"] = "read" }]
    ]

    cases.each do |name, mutate|
      result = run_deployed_script(&mutate)
      assert_match(/current trusted approval/, result.fetch("error"), name)
      assert_empty result.dig("calls", "updateAttempts"), name
    end
  end

  def test_deployed_script_rechecks_approval_immediately_before_writing
    result = run_deployed_script do |scenario|
      scenario["reviewSets"] = [[approved_review], []]
    end

    assert_match(/current trusted approval/, result.fetch("error"))
    assert_empty result.dig("calls", "updateAttempts")
  end

  def test_deployed_script_ignores_comments_after_an_admin_approval
    result = run_deployed_script do |scenario|
      reviews = [approved_review, approved_review.merge("id" => 2, "state" => "COMMENTED")]
      scenario["reviewSets"] = [reviews, reviews]
      scenario["permissions"]["reviewer"] = "admin"
    end

    assert_nil result.fetch("error")
    assert_equal 1, result.dig("calls", "updates").length
  end

  def test_deployed_script_noops_when_v1_is_already_current
    result = run_deployed_script do |scenario|
      scenario["refs"] = [tag_ref(SHA)]
    end

    assert_nil result.fetch("error")
    assert_empty result.dig("calls", "updateAttempts")
    assert_empty result.dig("calls", "comparisons")
    assert_includes result.fetch("notices"), "v1 already points to #{SHA}; no update needed"
  end

  def test_deployed_script_refuses_non_lightweight_tags
    result = run_deployed_script do |scenario|
      scenario["refs"] = [{ "object" => { "type" => "tag", "sha" => PRIOR_SHA } }]
    end

    assert_match(/lightweight commit tag/, result.fetch("error"))
    assert_empty result.dig("calls", "updateAttempts")
  end

  def test_deployed_script_refuses_a_malformed_tag_commit_sha
    result = run_deployed_script do |scenario|
      scenario["refs"] = [{ "object" => { "type" => "commit", "sha" => "invalid" } }]
    end

    assert_match(/lightweight commit tag/, result.fetch("error"))
    assert_empty result.dig("calls", "updateAttempts")
  end

  def test_deployed_script_refuses_backward_and_divergent_movements
    %w[behind diverged].each do |status|
      result = run_deployed_script do |scenario|
        scenario["comparisonStatus"] = status
      end

      assert_match(/non-fast-forward/, result.fetch("error"), status)
      assert_empty result.dig("calls", "updateAttempts"), status
    end
  end

  def test_deployed_script_refuses_a_remote_tag_race
    result = run_deployed_script do |scenario|
      scenario["refs"] = [tag_ref(PRIOR_SHA), tag_ref(DIVERGENT_SHA)]
    end

    assert_match(/changed before update/, result.fetch("error"))
    assert_empty result.dig("calls", "updateAttempts")
  end

  def test_deployed_script_surfaces_a_remote_read_failure_without_writing
    result = run_deployed_script do |scenario|
      scenario["getRefErrorAt"] = 0
      scenario["getRefError"] = "502 unavailable"
    end

    assert_match(/502 unavailable/, result.fetch("error"))
    assert_empty result.dig("calls", "updateAttempts")
  end

  def test_deployed_script_surfaces_an_update_api_failure_after_the_attempt
    result = run_deployed_script do |scenario|
      scenario["updateError"] = "403 forbidden"
    end

    assert_match(/403 forbidden/, result.fetch("error"))
    assert_equal 1, result.dig("calls", "updateAttempts").length
    assert_empty result.dig("calls", "updates")
  end

  def test_deployed_script_reports_a_post_write_mismatch_after_updating
    result = run_deployed_script do |scenario|
      scenario["refs"] = [tag_ref(PRIOR_SHA), tag_ref(PRIOR_SHA), tag_ref(DIVERGENT_SHA)]
    end

    assert_match(/post-write.*investigate remote state/, result.fetch("error"))
    assert_equal 1, result.dig("calls", "updates").length
  end

  def test_workflow_separates_untrusted_validation_from_trusted_post_merge_writes
    workflow = workflow_definition
    source = File.read(workflow_path)
    validate_job = workflow.fetch("jobs").fetch("validate")
    advance_job = workflow.fetch("jobs").fetch("advance")
    checkout = validate_job.fetch("steps").find { |step| step["name"] == "Checkout exact event commit" }

    assert_includes source, "pull_request:\n    types: [opened, synchronize, reopened]"
    assert_includes source, "pull_request_target:\n    types: [closed]"
    assert_includes source, "github.event_name == 'pull_request_target'"
    assert_includes source, "github.event.pull_request.merge_commit_sha == github.sha"
    assert_equal({ "contents" => "read" }, workflow.fetch("permissions"))
    assert_equal({ "contents" => "read" }, validate_job.fetch("permissions"))
    assert_equal false, checkout.fetch("with").fetch("persist-credentials")
    assert_includes checkout.fetch("with").fetch("ref"), "github.event.pull_request.merge_commit_sha"
    assert_equal({ "contents" => "write", "pull-requests" => "read" }, advance_job.fetch("permissions"))
    assert_equal "validate", advance_job.fetch("needs")
    assert_equal "major-channel-v1", advance_job.fetch("concurrency").fetch("group")
    assert_equal false, advance_job.fetch("concurrency").fetch("cancel-in-progress")
    assert_equal ["Advance the major channel"], advance_job.fetch("steps").map { |step| step["name"] }
    refute advance_job.fetch("steps").any? { |step| step.key?("run") || step.fetch("uses", "").include?("checkout") }
    assert_includes source, "actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683"
    assert_includes source, "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b"
    refute_match(/workflow_dispatch|schedule|secrets:|\n  push:/, source)
  end

  private

  def run_deployed_script
    scenario = JSON.parse(JSON.generate(default_scenario))
    yield scenario if block_given?
    input = JSON.generate("script" => deployed_script, "scenario" => scenario)
    output, error, status = Open3.capture3("node", harness_path, stdin_data: input)
    assert status.success?, "script harness failed: #{error}"

    JSON.parse(output)
  end

  def default_scenario
    {
      "context" => {
        "eventName" => "pull_request_target",
        "ref" => "refs/heads/main",
        "sha" => SHA,
        "repo" => { "owner" => "minekube", "repo" => "actions" },
        "payload" => {
          "action" => "closed",
          "number" => PULL_NUMBER,
          "repository" => { "full_name" => REPOSITORY, "default_branch" => "main" },
          "pull_request" => merged_pull_request
        }
      },
      "pull" => merged_pull_request,
      "reviewSets" => [[approved_review], [approved_review]],
      "permissions" => { "reviewer" => "write" },
      "comparisonStatus" => "ahead",
      "refs" => [tag_ref(PRIOR_SHA), tag_ref(PRIOR_SHA), tag_ref(SHA)],
      "getRefErrorAt" => nil,
      "getRefError" => nil,
      "updateError" => nil
    }
  end

  def merged_pull_request
    {
      "number" => PULL_NUMBER,
      "state" => "closed",
      "merged" => true,
      "merged_at" => "2026-07-19T00:00:00Z",
      "merge_commit_sha" => SHA,
      "head" => { "sha" => HEAD_SHA, "repo" => { "full_name" => "contributor/actions" } },
      "base" => { "ref" => "main", "repo" => { "full_name" => REPOSITORY } },
      "user" => { "login" => "contributor" }
    }
  end

  def approved_review
    {
      "id" => 1,
      "state" => "APPROVED",
      "commit_id" => HEAD_SHA,
      "submitted_at" => "2026-07-19T00:00:00Z",
      "user" => { "login" => "reviewer", "type" => "User" },
      "author_association" => "MEMBER"
    }
  end

  def tag_ref(sha)
    { "ref" => "refs/tags/v1", "object" => { "type" => "commit", "sha" => sha } }
  end

  def deployed_script
    workflow_definition.fetch("jobs").fetch("advance").fetch("steps").first.fetch("with").fetch("script")
  end

  def workflow_definition
    YAML.safe_load(File.read(workflow_path), aliases: false)
  end

  def workflow_path
    File.expand_path("../.github/workflows/advance-v1.yml", __dir__)
  end

  def harness_path
    File.expand_path("major_channel_script_harness.js", __dir__)
  end
end
