// Claim: resolve the ISO, then claim an appliance at the requested baseline.
// Everything the rest of the job needs comes out as outputs, and — unless
// export-env is off — as the TN_* environment the suites already read.
'use strict';

const {
  input, applianceEnv, appliance, setOutput, exportEnv, saveState, mask, group, endGroup, fail,
} = require('./lib');

function main() {
  const env = applianceEnv();
  const baseline = input('baseline') || 'fresh-install';

  group('Resolve the install ISO');
  const iso = appliance(env, 'iso');
  endGroup();
  if (!iso.TN_GUEST_ISO) {
    throw new Error('appliance.sh iso printed no TN_GUEST_ISO');
  }
  env.TN_GUEST_ISO = iso.TN_GUEST_ISO;

  group(`Claim an appliance (${baseline})`);
  const claim = appliance(env, 'claim', baseline);
  endGroup();
  for (const key of ['TN_PROFILE', 'TN_HOST', 'TN_HOST_HTTP', 'TN_USERNAME', 'TN_PASSWORD', 'TN_DOMAIN', 'TN_BASELINE']) {
    if (!claim[key]) {
      throw new Error(`appliance.sh claim printed no ${key}`);
    }
  }

  // Before the password can reach any log line, output or environment dump.
  mask(claim.TN_PASSWORD);

  // The post step needs only the domain; the file appliance.sh wrote under
  // RUNNER_TEMP is its fallback for a claim that died before printing one.
  saveState('domain', claim.TN_DOMAIN);

  const outputs = {
    'profile': claim.TN_PROFILE,
    'host': claim.TN_HOST,
    'host-http': claim.TN_HOST_HTTP,
    'username': claim.TN_USERNAME,
    'password': claim.TN_PASSWORD,
    'domain': claim.TN_DOMAIN,
    'baseline': claim.TN_BASELINE,
    'iso': iso.TN_GUEST_ISO,
    'iso-source': iso.TN_GUEST_ISO_SOURCE ?? '',
  };
  for (const [key, value] of Object.entries(outputs)) {
    setOutput(key, value);
  }

  if (input('export-env') !== 'false') {
    for (const key of ['TN_PROFILE', 'TN_HOST', 'TN_HOST_HTTP', 'TN_USERNAME', 'TN_PASSWORD', 'TN_DOMAIN', 'TN_BASELINE']) {
      exportEnv(key, claim[key]);
    }
    exportEnv('TN_GUEST_ISO', iso.TN_GUEST_ISO);
  }

  process.stdout.write(`Claimed ${claim.TN_DOMAIN} at ${claim.TN_HOST} (${claim.TN_BASELINE}, ${iso.TN_GUEST_ISO_SOURCE ?? 'iso'})\n`);
}

try {
  main();
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
