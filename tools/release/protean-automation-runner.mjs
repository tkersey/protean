import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {ProteanProposalClient} from './protean-proposal-github.mjs';
import {githubCommand} from './github.mjs';
import {jobPermissions} from './app-token.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular} from './review-owner.mjs';
import {readReviewResult} from './review-result.mjs';
import {automationMode} from './review-observer.mjs';
import {reportProteanReview} from './review-check.mjs';
import {proteanPreparationPlan} from './protean-preparation-plan.mjs';
import {readProteanPreparation} from './protean-preparation-artifact.mjs';
import {nativeCandidateBinding} from './protean-proposal.mjs';
import {manifestOperations} from './protean-native-manifest.mjs';
import {sourceManifest} from './release-observation.mjs';
import {proposeProtean, promoteProtean, pauseProteanProposals, recoverProposalMetadata} from './protean-proposal.mjs';
import {createProteanPromotionAdmission} from './protean-promotion-admission.mjs';
import {admitOwnerResume, reportAutomationStatus} from './proposal-authority.mjs';
import {appActor, currentProteanSource, proteanBoundaryOperations, originalProteanQualification,
  observationPages, preparationPulls, promotionRequirements, storedProteanCandidate, admitUnproposedProtean, retireProteanProposal, frozenProteanCandidate} from './release-observation.mjs';

function writerIdentity(identity) {
  assert.equal(identity.repository, 'tkersey/protean'); assert.equal(identity.repositoryId, 1328996555);
  assert.equal(identity.role, 'writer'); assert.deepEqual(identity.permissions, jobPermissions.writer);
  assert.ok(Date.parse(identity.expiresAt) > Date.now(), 'repository writer credential expired');
}

function reason(error) {
  return String(error.message).slice(0, 12000);
}

export function automationOperations({client, command, native, actor}) {
  return {
    recover: pull => recoverProposalMetadata({pull, actor, client,
      readCandidate: head => storedProteanCandidate(head, {client, command, native, actor}),
      admitRetirement: retireProteanProposal({client, command, native, actor}),
      admitResume: value => admitOwnerResume(value, client)}),
    plan: (source,frozen=null) => proteanPreparationPlan({source,client,command,native,actor,frozen}),
    freeze: (pull,source) => frozenProteanCandidate(pull,source,{client,command}),
    preparation: selection => readProteanPreparation(selection,command),
    retire: retireProteanProposal({client, command, native, actor}),
    orphan: admitUnproposedProtean({client, command, native, actor}),
    resume: value => admitOwnerResume(value, client),
    propose: value => proposeProtean({...value, actor, client}),
    promote: value => promoteProtean({...value, actor, client}),
    qualification: head => originalProteanQualification(head, command),
    requirements: (base, appId) => promotionRequirements(base, appId, client),
    promotion: options => createProteanPromotionAdmission({...options, client, command,
      authenticateReview: subject => readReviewResult({repository: 'tkersey/protean', ...subject}, command)}),
  };
}

export async function runProteanAutomation({controlCommit, identity = null, native, configuredMode = 'off'}, {
  client = new ProteanProposalClient(), command = githubCommand,
  actorReader = appActor, sourceReader = currentProteanSource, pause = pauseProteanProposals,
  reportReview = reportProteanReview, reportStatus = reportAutomationStatus,
  operations = automationOperations,
} = {}) {
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  assert.equal(typeof native?.read, 'function');
  let actor = null, pauses = [];
  if (identity !== null) {
    writerIdentity(identity); actor = await actorReader(identity, command);
    try { pauses = await pause({actor, client}); }
    catch (error) { return {status: 'blocked', pauseVerified: false, reason: reason(error)}; }
  }
  if (actor === null) assert.ok(['off', 'propose', 'promote'].includes(configuredMode), 'invalid configured automation mode');
  const mode = actor === null ? configuredMode : await automationMode(client), source = await sourceReader(client);
  const pendingVersion = native.read(await sourceManifest(client, source.commit));
  const checks = [];
  if (actor !== null) {
    const pulls = await observationPages(client, '/pulls?state=open&base=main');
    for (const pull of pulls.filter(value => value.head.repo?.id === 1328996555 && value.base.repo?.id === 1328996555)) {
      try {
        checks.push({number: pull.number, ...await reportReview({number: pull.number, appId: identity.appId},
          {client, readResult: subject => readReviewResult(subject, command)})});
      } catch (error) { checks.push({number: pull.number, status: 'blocked', reason: reason(error)}); }
    }
  }
  const observed = {mode, modeSource: actor === null ? 'workflow configuration' : 'live repository variable',
    source, pendingVersion, pauses, checks, pauseVerified: actor !== null};
  if (actor === null) {
    const releases = await observationPages(client, '/releases');
    return {...observed, status: mode === 'off' ? 'disabled' : 'blocked',
      reason: 'Repository App writer is unavailable. Source and release observations are read-only; existing auto-merge cancellation is unverified.',
      releases: releases.map(value => ({id: value.id, tag: value.tag_name, draft: value.draft, prerelease: value.prerelease}))};
  }
  if (mode === 'off') return {...observed, status: 'disabled'};
  if (source.commit !== controlCommit) return {...observed, status: 'held', reason: 'Trusted control checkout is stale; observe the current main revision.'};
  const actions = operations({client, command, native, actor});
  let currentPull = null, candidate = null;
  const finish = async value => {
    if (currentPull !== null) {
      try { value.comment = await reportStatus({number: currentPull.number, actor, appId: identity.appId,
        state: {status: value.status, reason: value.reason ?? null, version: candidate?.version ?? null}}, client); }
      catch (error) { value.comment = {status: 'blocked', reason: reason(error)}; }
    }
    return {...observed, ...value};
  };
  try {
    const pulls = await preparationPulls(client);
    currentPull = pulls.find(pull => pull.state === 'open') ?? null;
    const recovery = await actions.recover(currentPull);
    if (recovery !== null) {candidate = recovery.candidate; return finish(recovery.result);}
    const frozen=await actions.freeze(currentPull,source);
    const plan=await actions.plan(source,frozen);
    if(plan.status!=='prepare')return finish(plan);
    const original=await actions.preparation({base:source.commit,...(frozen===null?{}:{head:frozen.head}),kosmosRecordSha256:plan.decision.kosmosRecordSha256,version:plan.decision.version});
    if(original===null)return finish({status:'preparation pending',reason:'The original unprivileged native preparation must finish before proposal writes.'});
    candidate=original.candidate;
    assert.equal(candidate.base,source.commit);assert.equal(candidate.version,plan.decision.version);
    const admitCandidate=async({candidate:proposed})=>{
      const current=await sourceReader(client),accepted=await actions.plan(current,frozen);
      assert.equal(current.commit,proposed.base,'native candidate base changed');
      assert.equal(accepted.status,'prepare','current source no longer requires preparation');
      const retained=await actions.preparation({base:proposed.base,head:proposed.head,
        kosmosRecordSha256:accepted.decision.kosmosRecordSha256,version:accepted.decision.version});
      assert.ok(retained,'original native preparation disappeared');
      assert.deepEqual(retained.decisionBytes,original.decisionBytes,'preparation decision changed');
      assert.deepEqual(nativeCandidateBinding(proposed),retained.binding,'proposal differs from original native generation');
      return retained.binding;
    };
    const proposed = await actions.propose({candidate, admitCandidate, admitRetirement: actions.retire, admitResume: actions.resume, admitOrphan: actions.orphan});
    if (proposed.number !== undefined) currentPull = {number: proposed.number};
    if (proposed.status !== 'proposal open') return finish(proposed);
    const review = await reportReview({number: proposed.number, appId: identity.appId},
      {client, readResult: subject => readReviewResult(subject, command)});
    const currentMode = await automationMode(client);
    if (currentMode !== 'promote') {
      observed.mode = currentMode;
      try { observed.pauses.push(...await pause({actor, client})); }
      catch (error) { observed.pauseVerified = false; throw error; }
      return finish({...proposed, review});
    }
    const run = await actions.qualification(candidate.head);
    if (run === null || run.status !== 'completed') return finish({status: 'qualification pending', number: proposed.number});
    if (run.conclusion !== 'success') return finish({status: 'held', number: proposed.number,
      reason: 'The original qualification failed; preserve that result until an admitted successor exists.'});
    if (review.conclusion !== 'success') return finish({status: 'review pending', number: proposed.number, review});
    const expected = await actions.requirements(candidate.base, identity.appId);
    const admitPromotion = actions.promotion({expected, qualificationRunId: run.id, admitCandidate});
    const promoted = await actions.promote({candidate, number: proposed.number, admitPromotion, admitResume: actions.resume});
    return finish(promoted);
  } catch (error) { return finish({status: 'held', reason: reason(error)}); }
}

if (import.meta.main) {
  const [controlDirectory, toolPath, compilerPath, identityPath] = process.argv.slice(2);
  assert.ok(controlDirectory && toolPath && compilerPath && process.argv.length <= 6);
  const root = resolve(controlDirectory);
  const git = args => execFileSync('git', ['--no-replace-objects', ...args], {cwd: root, encoding: 'utf8', timeout: 30000}).trim();
  const controlCommit = git(['rev-parse', 'HEAD']);
  assert.equal(git(['status', '--porcelain=v1', '--untracked-files=no']), '', 'trusted control checkout changed');
  if (process.env.GITHUB_SHA) assert.equal(controlCommit, process.env.GITHUB_SHA);
  const identity = identityPath ? parseEvidenceJson(readRegular(resolve(identityPath), 1024 * 1024)) : null;
  const result = await runProteanAutomation({controlCommit, identity, configuredMode: process.env.REPOSITORY_AUTOMATION || 'off', native: manifestOperations(resolve(toolPath),resolve(compilerPath))});
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `\nRepository automation observation\n\n\`\`\`json\n${JSON.stringify(result, null, 2)}\n\`\`\`\n`);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (result.status === 'blocked' || result.comment?.status === 'blocked' ||
      result.checks?.some(check => check.status === 'blocked')) process.exitCode = 1;
}
