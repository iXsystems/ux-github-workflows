// Shared by main.js and post.js. Built-ins only: no node_modules to bundle,
// nothing to keep in sync with @actions/core.
'use strict';

const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const script = path.join(__dirname, 'appliance.sh');

// Inputs arrive as INPUT_<NAME>, the name uppercased with its dashes kept.
function input(name) {
  return (process.env[`INPUT_${name.toUpperCase()}`] ?? '').trim();
}

// Which input feeds which of appliance.sh's environment variables. An empty
// input unsets the variable so the script's own default applies, whatever the
// job environment happens to carry.
const inputToEnv = {
  'tn-guest': 'TN_GUEST',
  'python': 'TN_GUEST_PYTHON',
  'host': 'TN_GUEST_HOST',
  'pool': 'TN_GUEST_POOL',
  'host-user': 'TN_GUEST_HOST_USER',
  'host-api-key': 'TN_GUEST_HOST_API_KEY',
  'host-password': 'TN_GUEST_HOST_PASSWORD',
  'iso': 'TN_GUEST_ISO',
  'iso-dir': 'TN_GUEST_ISO_DIR',
  'iso-index': 'TN_GUEST_ISO_INDEX',
  'iso-series': 'TN_GUEST_ISO_SERIES',
  'iso-max-age-days': 'TN_GUEST_ISO_MAX_AGE_DAYS',
  'iso-keep': 'TN_GUEST_ISO_KEEP',
  'template-prefix': 'TN_GUEST_TEMPLATE_PREFIX',
  'template-password': 'TN_GUEST_TEMPLATE_PASSWORD',
  'lifetime': 'TN_GUEST_LIFETIME',
  'memory-mb': 'TN_GUEST_MEMORY_MB',
  'vcpus': 'TN_GUEST_VCPUS',
  'os-disk-gb': 'TN_GUEST_OS_DISK_GB',
  'data-disk-count': 'TN_GUEST_DATA_DISK_COUNT',
  'data-disk-gb': 'TN_GUEST_DATA_DISK_GB',
};

function applianceEnv() {
  const env = { ...process.env };
  for (const [name, variable] of Object.entries(inputToEnv)) {
    const value = input(name);
    if (value) {
      env[variable] = value;
    } else {
      delete env[variable];
    }
  }
  if (input('refresh-iso') === 'true') {
    env.TN_GUEST_ISO_REFRESH = '1';
    // A refresh is a decision about this run and beats a standing pin.
    delete env.TN_GUEST_ISO;
  } else {
    delete env.TN_GUEST_ISO_REFRESH;
  }
  return env;
}

// Run one appliance.sh verb. Its stderr — tn_guest.py's progress included —
// goes straight to the job log; its stdout, the KEY=VALUE contract, comes
// back parsed. A non-zero exit is an Error carrying the verb.
function appliance(env, verb, ...args) {
  const result = spawnSync('bash', [script, verb, ...args], {
    env,
    stdio: ['ignore', 'pipe', 'inherit'],
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`appliance.sh ${verb}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`appliance.sh ${verb} exited with ${result.status}`);
  }
  return parseKeyValues(result.stdout);
}

function parseKeyValues(text) {
  const values = {};
  for (const line of text.split('\n')) {
    const match = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line);
    if (match) {
      values[match[1]] = match[2];
    }
  }
  return values;
}

// The runner's command files. Appending a line is how outputs, environment
// and state are set without @actions/core. Values are single-line here, so
// the plain KEY=VALUE form is enough and the heredoc form is not needed.
function appendCommandFile(variable, key, value) {
  const file = process.env[variable];
  if (!file) {
    throw new Error(`${variable} is not set; is this running under the GitHub runner?`);
  }
  if (/[\r\n]/.test(value)) {
    throw new Error(`${key} has a newline in it, refusing to write it to ${variable}`);
  }
  fs.appendFileSync(file, `${key}=${value}\n`);
}

const setOutput = (key, value) => appendCommandFile('GITHUB_OUTPUT', key, value);
const exportEnv = (key, value) => appendCommandFile('GITHUB_ENV', key, value);
const saveState = (key, value) => appendCommandFile('GITHUB_STATE', key, value);

// Workflow commands on stdout. `add-mask` is the one that matters: the
// appliance password is generated per claim, so nothing masks it for us.
function mask(value) {
  if (value) {
    process.stdout.write(`::add-mask::${value}\n`);
  }
}
const group = (title) => process.stdout.write(`::group::${title}\n`);
const endGroup = () => process.stdout.write('::endgroup::\n');
const fail = (message) => {
  process.stdout.write(`::error::${message}\n`);
  process.exitCode = 1;
};

module.exports = {
  input, applianceEnv, appliance, setOutput, exportEnv, saveState, mask, group, endGroup, fail,
};
