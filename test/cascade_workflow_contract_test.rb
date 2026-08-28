#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
CANONICAL_APP_TOKEN = "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1"
RUNNER_LABEL = "ubuntu-24.04"
CONSUMERS = %w[bump-go-module.yml dispatch-workflow.yml].freeze

def assert(errors, condition, message)
  errors << message unless condition
end

def workflow(path)
  YAML.safe_load(File.read(path), aliases: false)
end

# Psych parses YAML 1.1 booleans, so a workflow's `on:` key arrives as
# boolean true. GitHub Actions reads YAML 1.2, where `on` is a plain key.
def workflow_call_inputs(path)
  document = workflow(path)
  on = document["on"] || document[true]
  on.fetch("workflow_call").fetch("inputs")
end

errors = []

# No workflow in this repository may route through the Akua runner control
# plane. The control plane (https://runner-control-plane.robinbraemer.workers.dev)
# has been down since 2026-08-17, and every release-cascade run that asked it
# for a runner failed before doing any work.
workflow_paths = Dir.glob(File.join(ROOT, ".github/workflows/*.{yml,yaml}")).sort
workflow_paths.each do |path|
  document = workflow(path)
  jobs = document.fetch("jobs", {})
  jobs.each do |job_name, job|
    uses = job["uses"] if job.is_a?(Hash)
    next unless uses.is_a?(String)

    assert(errors, !uses.include?("runner-plan.yml"),
           "#{File.basename(path)} job #{job_name} still calls the Akua runner control plane (#{uses})")
  end
end

CONSUMERS.each do |filename|
  path = File.join(ROOT, ".github/workflows", filename)
  jobs = workflow(path).fetch("jobs")
  consumer = jobs.fetch(filename == "bump-go-module.yml" ? "bump" : "dispatch")

  assert(errors, !jobs.key?("runner-plan"),
         "#{filename} still has the runner-plan job; the Akua control plane has been down since 2026-08-17")
  assert(errors, consumer["needs"] != "runner-plan",
         "#{filename} consumer must not depend on the runner-plan job")
  assert(errors, consumer["runs-on"] == RUNNER_LABEL,
         "#{filename} consumer must run directly on GH-hosted #{RUNNER_LABEL}, not a runner-plan label")

  call_inputs = workflow_call_inputs(path)
  assert(errors, !call_inputs.key?("runner-control-plane-url"),
         "#{filename} still exposes the dead runner-control-plane-url input")
  assert(errors, !call_inputs.key?("runner-oidc-audience"),
         "#{filename} still exposes the runner-oidc-audience input")

  perms = workflow(path).fetch("permissions", {})
  assert(errors, !perms.key?("id-token"),
         "#{filename} still requests id-token: write at workflow level; no OIDC control-plane auth remains")

  client_id_input = call_inputs["release-cascade-app-client-id"]
  assert(errors, client_id_input == {
           "description" => "GitHub App client ID used for the cross-repository dispatch.",
           "required" => false, "type" => "string", "default" => ""
         },
         "#{filename} must expose the release-cascade App client ID input without breaking existing v1 callers")

  token_step = consumer.fetch("steps").find { |step| step["name"] == "Create GitHub App token" }
  assert(errors, token_step.is_a?(Hash),
         "#{filename} must create its GitHub App token explicitly")
  next unless token_step.is_a?(Hash)

  assert(errors, token_step["uses"] == CANONICAL_APP_TOKEN,
         "#{filename} must pin the GitHub App token action to the reviewed v3.2.0 commit")
  token_inputs = token_step.fetch("with", {})
  assert(errors, token_inputs["client-id"] == "${{ inputs.release-cascade-app-client-id || vars.RELEASE_CASCADE_APP_CLIENT_ID }}",
         "#{filename} must prefer the explicit GitHub App client ID input with a v1-compatible fallback")
  assert(errors, !token_inputs.key?("app-id"),
         "#{filename} must not use the deprecated GitHub App ID input")
  assert(errors, token_inputs["private-key"] == "${{ secrets.RELEASE_CASCADE_APP_PRIVATE_KEY }}",
         "#{filename} must use the release-cascade private key secret")
end

abort "release-cascade workflow contract failed:\n- #{errors.join("\n- ")}" unless errors.empty?

puts "release-cascade workflow contract passed"
