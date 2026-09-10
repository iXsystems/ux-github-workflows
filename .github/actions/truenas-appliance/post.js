// Release: runs on success, failure and cancellation (post-if: always()).
// Never fails the job — appliance.sh release is itself written to return 0,
// because a teardown that throws masks the failure that mattered — and runs
// even when main never got as far as saving a domain: release then falls
// back to the name appliance.sh recorded under RUNNER_TEMP before creating
// anything, so a claim that died between create and print is still released.
'use strict';

const { applianceEnv, appliance, group, endGroup } = require('./lib');

try {
  const domain = process.env.STATE_domain ?? '';
  group(`Release the appliance${domain ? ` (${domain})` : ''}`);
  appliance(applianceEnv(), 'release', domain);
  endGroup();
} catch (error) {
  // Warn, not fail: the lease (lifetime) is the guarantee behind this step,
  // and a job that already failed must report its own failure, not this one.
  process.stdout.write(`::warning::release did not complete: ${error instanceof Error ? error.message : String(error)}\n`);
}
