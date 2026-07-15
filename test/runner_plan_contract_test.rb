#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
CANONICAL_RUNNER_PLAN = "akua-dev/actions/.github/workflows/runner-plan.yml@9d86a1802f2ebc29c7d5770a4ffff7bb84b6cdc0"
RETIRED_RUNNER_PLAN = "cnap-tech/actions/.github/workflows/runner-plan.yml"
CONSUMERS = %w[bump-go-module.yml dispatch-workflow.yml].freeze

def assert(errors, condition, message)
  errors << message unless condition
end

def workflow(path)
  YAML.safe_load(File.read(path), aliases: false)
end

errors = []
workflow_paths = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).sort
runner_plan_callers = []

workflow_paths.each do |path|
  document = workflow(path)
  jobs = document.fetch("jobs", {})

  jobs.each do |job_name, job|
    uses = job["uses"] if job.is_a?(Hash)
    next unless uses.is_a?(String)

    assert(errors, !uses.start_with?(RETIRED_RUNNER_PLAN),
           "#{File.basename(path)} job #{job_name} still uses the retired cnap-tech coordinate")

    next unless uses.include?("/.github/workflows/runner-plan.yml@")

    runner_plan_callers << File.basename(path)

    assert(errors, uses == CANONICAL_RUNNER_PLAN,
           "#{File.basename(path)} job #{job_name} must use the canonical immutable runner-plan coordinate")
    ref = uses.split("@", 2).last
    assert(errors, ref.match?(/\A[0-9a-f]{40}\z/),
           "#{File.basename(path)} job #{job_name} must pin runner-plan to a 40-character SHA")
  end
end

assert(errors, runner_plan_callers.sort == CONSUMERS,
       "runner-plan callers must be #{CONSUMERS.join(", ")}")

CONSUMERS.each do |filename|
  path = File.join(ROOT, ".github/workflows", filename)
  jobs = workflow(path).fetch("jobs")
  runner_plan = jobs.fetch("runner-plan")
  consumer = jobs.fetch(filename == "bump-go-module.yml" ? "bump" : "dispatch")

  assert(errors, runner_plan["uses"] == CANONICAL_RUNNER_PLAN,
         "#{filename} runner-plan job must call the canonical workflow")
  assert(errors, runner_plan["with"] == {
           "control-plane-url" => "${{ inputs.runner-control-plane-url }}",
           "oidc-audience" => "${{ inputs.runner-oidc-audience }}",
           "jobs-json" => '{"linux_x64":"linux-x64"}'
         }, "#{filename} runner-plan inputs changed")
  assert(errors, consumer["needs"] == "runner-plan",
         "#{filename} consumer must depend on runner-plan")
  assert(errors, consumer["runs-on"] == "${{ fromJSON(needs.runner-plan.outputs.linux_x64) }}",
         "#{filename} consumer must use the linux_x64 runner-plan output")
end

abort "runner-plan workflow contract failed:\n- #{errors.join("\n- ")}" unless errors.empty?

puts "runner-plan workflow contract passed"
