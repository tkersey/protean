import {deployment} from './native_deployment.mjs';
import {verifyAdaptiveRuntime} from './adaptive_native_peer.mjs';

const app = deployment(process.argv[2], 'protean');
let passed = false;
try {
  const result = await verifyAdaptiveRuntime({app, applicationPath: process.argv[3], scenarios: process.argv[4] ? process.argv[4].split(',') : undefined, sourcePeer: process.argv[5]});
  passed = true;
  console.log(JSON.stringify({runtime_choices: result, scripted_provider: true, live_model_efficacy: 'unmeasured'}));
} finally {
  await app.close(passed);
}
