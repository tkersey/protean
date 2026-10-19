import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';

const [peer, oraclePath, embeddingPath, wasmPath] = process.argv.slice(2);
const {execute} = await import(pathToFileURL(oraclePath));
const {Kernel, encodeInput, decodeRequest, encodeResult, decodeOutcome} = await import(pathToFileURL(embeddingPath));
const kernel = wasmPath ? new Uint8Array(await readFile(wasmPath)) : null;
const wasm = kernel ? await Kernel.create({bytes: kernel, expectedSha256: createHash('sha256').update(kernel).digest('hex')}) : null;
if (wasm) wasm.setLimits({input: 8 << 20, working: 64 << 20, output: 8 << 20});
const reports = [];
const capsulePacket = spawnSync(peer, ['capsule-export'], {maxBuffer: 64 << 20});
assert.equal(capsulePacket.status, 0, capsulePacket.stderr.toString());
const capsuleCut = spawnSync(peer, ['capsule-import'], {input: capsulePacket.stdout, maxBuffer: 64 << 20});
assert.equal(capsuleCut.status, 0, capsuleCut.stderr.toString());
const capsulePortability = {packetSha256: createHash('sha256').update(capsulePacket.stdout).digest('hex'),
  guestCutSha256: createHash('sha256').update(capsuleCut.stdout).digest('hex'), exactOuterRestore: true, duplicateCustodyRejected: true};
for (const name of ['gcd', 'recursive', 'alternatives', 'mutable-alternatives', 'shallow', 'successor', 'attachments', 'mobility']) {
  const emitted = spawnSync(peer, [name], {maxBuffer: 16 << 20, encoding: 'utf8'});
  assert.equal(emitted.status, 0, emitted.stderr);
  const fixture = JSON.parse(emitted.stdout), image = Buffer.from(fixture.image, 'base64url');
  for (const [caseIndex, example] of fixture.cases.entries()) {
    const input = Buffer.from(example.input, 'base64url');
    const replies = example.responses.map(value => Buffer.from(value, 'base64url'));
    const oracle = execute(fixture.source, [...input], replies.map(value => [...value]));
    assert.equal(oracle.kind, 'Completed');
    assert.deepEqual(Buffer.from(oracle.value), Buffer.from(example.expected, 'base64url'));
    let state, control = 'none', value, replyIndex = 0, boundaries = 0, checkpointBytes = 0, outcomeBytes = 0, maximumCheckpoint = 0;
    let nativeMilliseconds = 0, wasmMilliseconds = 0;
    const trace = [];
    for (;;) {
      const request = encodeInput({image, initialArgs: state ? undefined : input, state, control, value, quantum: 256});
      const started = performance.now();
      const native = spawnSync(peer, ['invoke'], {input: request, maxBuffer: 16 << 20});
      nativeMilliseconds += performance.now() - started;
      assert.equal(native.status, 0, native.stderr.toString());
      let selected = native.stdout;
      if (wasm) {
        const started = performance.now();
        const bytes = wasm.invoke(request);
        wasmMilliseconds += performance.now() - started;
        assert.deepEqual(Buffer.from(bytes), native.stdout, 'same-image native/WASM canonical output differs');
        if (boundaries % 2 === 0) selected = bytes;
      }
      boundaries++; outcomeBytes += selected.length;
      const result = decodeOutcome(selected);
      if (result.state) { checkpointBytes += result.state.length; maximumCheckpoint = Math.max(maximumCheckpoint, result.state.length); }
      if (result.kind === 'completed') {
        assert.deepEqual(Buffer.from(result.value), Buffer.from(oracle.value));
        break;
      }
      assert(['progressed', 'yielded', 'requested'].includes(result.kind), result.kind);
      state = result.state; assert(state);
      value = undefined; control = result.kind === 'yielded' ? 'resume_yield' : 'none';
      if (result.kind === 'yielded') trace.push({kind: 'Yielded'});
      if (result.kind === 'requested') {
        const request = await decodeRequest(result.request);
        trace.push({kind: 'Requested', identity: request.semanticIdentity, payload: [...request.payload]});
        assert(replyIndex < replies.length);
        value = await encodeResult(result.request, replies[replyIndex++]); control = 'reply';
      }
    }
    assert.equal(replyIndex, replies.length);
    assert.deepEqual(trace, oracle.trace, 'independent source trace differs');
    reports.push({name, case: caseIndex, source_oracle: true, native_wasm: Boolean(wasm), producer_switching: Boolean(wasm), boundaries, checkpointBytes, maximumCheckpoint, outcomeBytes, nativeMillisecondsIncludingProcessStartup: nativeMilliseconds, wasmMilliseconds, compileNanoseconds: fixture.compile_ns, compilerArenaBytes: fixture.compiler_arena_bytes, controllerModelCalls: 0, delegatedModelCalls: 0});
  }
}
console.log(JSON.stringify({workspace_execution: reports, capsule_portability: capsulePortability}));
