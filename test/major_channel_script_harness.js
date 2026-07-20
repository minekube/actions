const fs = require("fs");

const input = JSON.parse(fs.readFileSync(0, "utf8"));
const scenario = input.scenario;
const calls = {
  pulls: [],
  reviews: [],
  permissions: [],
  comparisons: [],
  getRefs: [],
  updateAttempts: [],
  updates: []
};
const notices = [];
let reviewIndex = 0;
let refIndex = 0;

function current(values, index) {
  return values[Math.min(index, values.length - 1)];
}

const github = {
  paginate: async (_request, options) => {
    calls.reviews.push(options);
    return current(scenario.reviewSets, reviewIndex++);
  },
  rest: {
    pulls: {
      get: async (options) => {
        calls.pulls.push(options);
        return { data: scenario.pull };
      },
      listReviews: async () => ({ data: [] })
    },
    repos: {
      getCollaboratorPermissionLevel: async (options) => {
        calls.permissions.push(options);
        return { data: { permission: scenario.permissions[options.username] || "none" } };
      },
      compareCommitsWithBasehead: async (options) => {
        calls.comparisons.push(options);
        return { data: { status: scenario.comparisonStatus } };
      }
    },
    git: {
      getRef: async (options) => {
        const index = refIndex++;
        calls.getRefs.push(options);
        if (scenario.getRefErrorAt === index) throw new Error(scenario.getRefError);
        return { data: current(scenario.refs, index) };
      },
      updateRef: async (options) => {
        calls.updateAttempts.push(options);
        if (scenario.updateError) throw new Error(scenario.updateError);
        calls.updates.push(options);
        return { data: { ref: `refs/${options.ref}`, object: { type: "commit", sha: options.sha } } };
      }
    }
  }
};
const core = { notice: (message) => notices.push(message) };
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const run = new AsyncFunction("github", "context", "core", input.script);

run(github, scenario.context, core).then(
  () => process.stdout.write(JSON.stringify({ error: null, calls, notices })),
  (error) => process.stdout.write(JSON.stringify({ error: error.message, calls, notices }))
);
