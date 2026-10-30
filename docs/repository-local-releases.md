# Repository-local releases: Protean

Status: native refresh, source production, separate preparation and writer workflows, original review ownership, qualification admission, and immutable publication are implemented locally. Final native qualification, serial implementation reviews, deployment, and live commissioning remain outstanding until their required evidence is retained. This document replaces the Protean portion of the proposed shared `align` / coordinated-stack-publication architecture.

## Decision and invariant

Protean discovers an eligible published Kosmos release, derives the exact Horos binding from that Kosmos, generates one ordinary Protean dependency/version-update PR, and publishes only Protean after its existing review and qualification.

There is one independent upstream selection: Kosmos. A refresh must not accept a separately configurable Horos revision. Its construction is:

```text
selected Kosmos -> read exact Horos binding -> authenticate both sources
               -> generate one Protean lock -> project Protean manifest
```

The accepted Protean lock defines the stack. Do not introduce an independently editable stack registry, shared `align` application, `skills-zig` product-specific tooling, central controller, scheduler database, coordinated release transaction, or cross-repository writer. Protean does not publish Horos or Kosmos on their behalf.

Automatic propagation follows qualified publications, not every qualified development commit. Existing development selections remain reproducible during bootstrap. Do not downgrade to an older published release to make the new workflow appear current.

## Existing ownership

`conformance/protean/dependencies.lock.json` owns native source selection. Its historical `boundary` and `world` fields mean Horos and Kosmos and remain unchanged. `build.zig.zon` must be a checked projection of the selected Horos binding and package identity. `tools/native/dependencies.zig` owns authenticated acquisition, inventory and package admission, and build-manifest production. Extend or factor that implementation rather than writing a parallel hashing or normalization algorithm.

The inspected baseline was commit `e4bbeaa1739905579f798c1bef5b72d9c4523d60`, package 8.0.0, Zig 0.17.0, selecting Horos `7d34f2c72e818665be4d519fde4f2cef9c986048` and Kosmos `e3ac443b97c31bda4ebe42b7cafb99e4ce721906`. These are historical inspection coordinates, not update targets. Inspect current source and active work before implementation.

The native dependency tool now exposes `refresh`, `coherence`, `source`, `source-build`, `source-manifest` and `verify-release-source` alongside setup and build-manifest verification. The refresh uses native semantic manifest parsing and the existing authenticated source admission.

`.github/workflows/zig.yml`, `.github/CI.md`, and current repository instructions remain authoritative for native, placement, downstream, retained-runtime, source, and other qualification. Keep package versions separate from application contracts, protocol, ABI, and state formats.

## Repository-local discovery

Add scheduled and manually dispatchable discovery in this repository. Poll upstream releases; no cross-repository dispatch is needed. Use a local concurrency group and explicit owner-controlled mutation enablement. Scheduling is best-effort eventual discovery, not an exact response-time guarantee.

Paginate release observations and resolve tags to exact commits, including annotated tags. Distinguish selected, latest observed, and newest admissible successor on approved upstream lineage. Authenticate source, final artifact identities, publication, qualification, and retained evidence. Release text, timestamps, semantic versions, API ordering, or the platform's immutable flag alone do not prove eligibility.

Reject drafts, unsupported prereleases, malformed or ambiguous identities, mutable/version-colliding inputs, unapproved history changes, and automatic downgrades. Source-equivalent squash commits do not imply missing changes; tree equality does not transfer transport digests, executable identity, review subject, or qualification credit.

Freeze one admitted Kosmos publication. Read the Horos manifest binding from that immutable source, authenticate the exact Horos input, and require its matching completed qualified publication. A failure of either admission stops this update; do not substitute another Horos release.

## Native refresh and coherence

The refresh operation runs without GitHub write or publication credentials. Its input is one frozen authenticated Kosmos selection, not two independently selected upstream versions.

Extend the existing native admission implementation to produce the complete lock update: source commits and Git trees; archive URL, digest, and size; complete source inventories; the Horos Zig package identity and both existing permission-profile inventories; required API-file hashes; and all other existing admission fields. Use the exact admitted Zig compiler. Preserve unrelated SQLite/native-dependency bindings and compatibility metadata.

Authenticate complete source paths, Git blob identities, executable modes, and tree identity before accepting new metadata. A downloaded archive and a checksum of that same download are not independent evidence of its claimed source. Preserve protections against links, special files, traversal, duplicates, changing files, and ambiguous permission profiles. Do not trust cache names or ambient sibling working trees.

Generate `build.zig.zon` from that same admitted selection through a semantic parser or bounded typed writer. Do not maintain a second selection registry or perform regex-only URL/version replacement. The operation must be deterministic for the same inputs, must verify its output, and must reject unexpected paths or non-mechanical edits before proposing a commit.

Prepare a required Protean package-version change in the same candidate before final hashing, review, and qualification. Use the approved local compatibility/version policy, preserve a sufficient already approved pending version, and do not bump again on a repeated observation. A breaking migration requires normal source implementation and blocks routine dependency automation.

Add a local and CI coherence check using authenticated local inputs. It checks lock/manifest consistency, exact shared Horos commit and package hash against the selected Kosmos, source and package inventories, toolchain constraints, generated identities, and version mirrors. Deliberately mismatched commit/hash/version cases must fail. Ordinary builds must neither discover newer upstreams nor fail solely because an upstream release exists.

Historical `publicationObservation` fields must describe observations actually made when the candidate was generated. Do not rewrite a published source lock just to record a later release, and do not create self-referential source hashes. Current release evidence is external to the source-selection authority.

## Implemented source and artifact boundaries

Run the native refresh against one authenticated Kosmos record and its derived
Horos record store. Its JSON request contains the exact base commit/tree,
prepared package version, Kosmos record/archive/local Git repository, and upstream
record directory. The output is retained only after full source admission,
projection, package reconstruction and coherence succeed:

```sh
zig run tools/native/dependencies.zig -- refresh ROOT INPUT_JSON OUTPUT_ABSOLUTE ABS_ZIG
zig run tools/native/dependencies.zig -- coherence ROOT VERIFIED_SOURCES ABS_ZIG
zig run tools/native/dependencies.zig -- source ROOT OUTPUT_ABSOLUTE ABS_ZIG EXPECTED_COMMIT
zig run tools/native/dependencies.zig -- verify-release-source ROOT SOURCE_TAR SOURCE_JSON EXTRACT_ABSOLUTE ABS_ZIG
```

`source` retains immutable `source.tar` and `source.json` bytes from a clean exact
Git head. The receipt binds the full Git inventory, native parsed manifest,
package identity, both lock digests, compiler and selected dependency commits
and trees. A conflicting output remains unchanged. `zig build release-source`
uses a build-owned output directory and admits a changed clean head on later
builds while preserving those identities. Neither command establishes product
qualification by itself.

The existing downstream CI lane independently verifies and consumes that exact
full source archive before retaining it. Its native acquisition/build boundary
continues to reject Node and Python, and its installed consumer still rejects
changed Horos/Kosmos inputs and exercises execution and cancellation. The native
lane seals the final application archive against its already executed binary,
program and application bytes. Native placement consumes that same binary;
downstream builds independently. The terminal gate binds all three identities,
both source lock digests, the consumed source receipt and final native archive.

`protean-qualification.mjs` admits only the unique original automatic run with
all eleven lanes, TigerStyle and the terminal gate successful within the original
600-second clock. It retains the seven final source/product/identity payloads
with their original run, size and digest bindings. `protean-assemble.mjs` derives
Horos from the authenticated Kosmos publication and binds the source definitions
to the native Git inventory before constructing the Protean publication record.
The adapter does not accept an independently selected Horos release.

Frozen native producer fixtures exercise the exact source identities across the
three repositories. Their README files distinguish unpublished source evidence
from full qualification and authenticated publication. The raw single-file
artifact API path still requires a live Actions observation before deployment
can be claimed verified.

## One local PR and existing review machinery

Maintain one automation-owned dependency/version-preparation PR in Protean, assigned to `tkersey`. Record the frozen Kosmos and derived Horos identities, update rationale, compatibility/version decision, generated scope, and actual outstanding gate.

Once qualification starts, freeze the candidate. New upstreams become later work, not silent changes to the active head. A changed base or material input requires regeneration and fresh affected review/qualification evidence. Do not overwrite human edits, recreate a manually held candidate, or re-enable auto-merge after an owner hold. Inspect uncertain writes before retry; converged observations are no-ops.

Actuating/CAS retain review ownership: approved model/reasoning parity, original receipts, full auxiliary inventory, applicable focused-file reviews, adjudication, and five consecutive credited standard reviews on an unchanged candidate. Any missing unattended execution or authenticated closeout interface is an explicit implementation dependency. Do not implement a second review engine, local clean counter, or substitute label/comment/check-title verdict.

Protected automatic merge requires explicit enablement, effective protections, an unchanged admissible subject, allowed generated diff, complete qualification, complete credited review, and resolved threads. Required human approvals remain required unless the owner explicitly changes their policy. No direct `main` pushes or administrative bypass.

Preserve every existing qualification lane, supported platform, artifact identity comparison, retained-runtime check, first-attempt/original-trigger rule, and 600-second elapsed budget from workflow creation. New jobs stay within ten minutes without resetting product clocks. Missing, skipped, neutral, diagnostic, expired, wrong-subject, interrupted, or timed-out results do not pass. Do not retry a failed product subject until green or create empty commits to manufacture another admissible attempt.

## Protean-only publication

After merge, qualify the actual landed source and reconfirm the selected tuple. Once separately enabled, publish only Protean using its already-published Horos/Kosmos dependencies. A Protean-only change keeps those dependency identities fixed unless its reviewed candidate changes them.

Derive a compact release manifest from the accepted lock and original evidence. Record the exact three source commits/trees/versions, lock digest, existing upstream releases, toolchain/platform identities, final assets with sizes/digests, and qualification/review references. This is a publication record, not a new build authority or global transaction ID. Its checksum is detached, not self-referential.

Publish the actual qualified final artifacts. Verify a final packaging/signing transformation when it changes executable bytes. Retain required evidence before ephemeral CI artifacts expire. Do not claim npm, Homebrew, installation, or other distribution work merely because a GitHub asset exists.

The privileged publisher runs accepted control code in a separate fresh job and consumes authenticated tested artifacts; it does not build or execute candidate code with release credentials. Candidate build/review jobs have no branch-write or release credentials. Disable checkout credential persistence, pin actions/control tooling, and do not execute candidate-populated caches with publishing authority.

Re-read the tag and assets after writes. Identical existing publication is a no-op. A different source or asset under an existing version/name blocks rather than retags or overwrites. Inspect uncertain uploads before retry. An unsuccessful Protean publication remains local pending work; already valid upstream releases are not rolled back or republished.

## Enablement, verification, and completion

PR proposal, protected promotion, and local publication require explicit owner-controlled enablement. This contract does not authorize credential creation, repository administration, merges, releases, or installations. Existing tasks, executable/image bindings, retained runtimes, and persistent state remain untouched.

Test wrong transitive Horos bindings; corrupt source/archive/package/profile/API identities; deterministic refresh and version preparation; same-version different source; tree-equivalent squash cases; malformed/colliding publications; frozen input movement; base changes; human holds; duplicate/uncertain writes; missing review evidence; incomplete or wrong-attempt qualification; expired artifacts; final-byte substitution; and immutable publication collisions.

Live authorized testing must exercise a real Kosmos release handoff, generated Protean PR, full review, protected merge, actual post-merge qualification, and local final-artifact publication. Demonstrate normal clean installation and retained-task behavior without controller credentials or sibling checkouts. Mocks alone do not establish deployment.

The implementation is complete only when the native refresh, coherence gate, consumer workflow, original review integration, protected promotion, local publisher, and actual acceptance evidence exist. This document, a detector, a draft PR, or an unexecuted workflow does not satisfy completion. Report implemented, tested, qualified, enabled, published, and installed states separately.


### Publication of qualified Protean artifacts

The repository-local publisher runs on accepted main after original qualification
and owner review. It also observes its own hourly schedule. Both controls must
permit publication: REPOSITORY_AUTOMATION is propose or promote, and
RELEASE_PUBLICATION_ENABLED is true. Defaults are off and false.

The workflow compiles the accepted native manifest parser before introducing
credentials. A read-only App token admits the original landed qualification,
review history, exact final artifacts, and completed Kosmos and its derived Horos publication.
It selects the dependencies already recorded in this source. An unrelated newer
release cannot replace them. Missing matching publication is a concrete blocker.

The local commands are:

```sh
node tools/release/protean-publication-runner.mjs prepare "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/protean-publication-runner.mjs publish "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$PUBLISHER_IDENTITY"
```

Preparation seals the original source archive, inventory, executed native package and independent placement/downstream identities
with the original qualification, reviewed publication boundary, landing mapping,
owner closeout, and authenticated original review artifact envelopes. It records
compiler, publisher Node, and reviewer binary identities separately. It neither
rebuilds artifacts nor transfers executable qualification across equal Git trees.

The trusted workflow attests the finalized record and payloads with pinned
GitHub artifact attestation tooling, then obtains a separate repository-local
publication token. The writer verifies the expected signer and recomputes the
admission from original observations before staging and before publication.
Only missing identical assets are uploaded. Conflicting tags, drafts, or bytes
remain untouched. Publication requires immutable-release protection and finishes
by checking the platform release attestation, source tag, and every asset.
A matching completed release is a verified no-op, without a bookkeeping commit
or another version bump. An interrupted matching draft resumes from observed
missing assets; changed source or expired original evidence blocks recovery.

The release never installs an executable or migrates a saved task.
Live App-created PRs, protected merging, authenticated Actions model review,
immutable publication and interrupted-write recovery require an owner-approved
commissioning environment; local adapter tests do not establish those effects.

### Native preparation and ordinary proposal operation

`Repository preparation` observes its own hourly schedule and local qualification
and owner-review completions. It runs only when `REPOSITORY_AUTOMATION` is
`propose` or `promote`. Its accepted-main tool reads the committed ZON manifest,
admits published Kosmos records, derives the exact Horos publication from the selected Kosmos, selects a forward compatible successor, and
combines that patch impact with the original reviewed Protean publication boundary.
A pending higher approved version is preserved. A selected development pin ahead
of published Kosmos releases is never downgraded. A new major or breaking upstream
migration requires ordinary implementation and review.

The preparation job compiles its exact accepted native tool before obtaining an
App observer token. Native code runs inside the required network-isolated
bubblewrap sandbox under the scoped AppArmor profile, with no write credential
or host credential environment. It retains the exact two generated source files,
original result, source-manifest/refresh/coherence stdout and stderr, compiler and tool
identities, original admitted dependency record, and own version decision.
The workflow uploads a generation-start artifact before native generation.
An existing original preparation is reused; an interrupted or failed equivalent
generation remains held until its original evidence is recovered. Deleting or
expiring an artifact does not authorize another invocation.

`Repository automation` runs separately after preparation completes. It uses
only authenticated original preparation artifacts, validates exact native file
bytes against the proposed Git tree, and creates or advances the one ordinary
`automation/dependency-release` PR, assigned to `tkersey`. It does not regenerate
candidate source. The App writer token is minted only after the accepted native
manifest reader is compiled. The bounded native manifest reader receives only PATH and a private temporary directory; it reads data and does not execute candidate code.

The exact local entry points are:

```sh
node tools/release/protean-preparation-runner.mjs plan "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/protean-preparation-runner.mjs generate "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$OUTPUT" "$OBSERVER_IDENTITY"
node tools/release/protean-automation-runner.mjs "$CONTROL" "$NATIVE_TOOL" "$ZIG" "$WRITER_IDENTITY"
```

The workflow owns the original run ID and the start/result artifact uploads;
calling a local command alone does not create authenticated Actions evidence.
The two workflows use independent serialized concurrency groups with cancellation
disabled and retain the 600-second job ceiling. Native generation also has a
shared 600-second process deadline with group cleanup. Required qualification
and the owner model's original policy and review counts remain unchanged.

Promotion uses the original successful qualification and exact owner closeout,
checks effective branch protection, and requests protected rebase auto-merge.
`propose`, `off`, a draft, or `automation-hold` cancels automation-owned pending
auto-merge. Failed qualification, unresolved review, stale bases, edited heads,
and unavailable original evidence hold the proposal. An admitted successor
requires closure of the original epoch. Automation never treats an owner closure
or manually disabled auto-merge as permission to resume. After reopening and
removing a hold, the repository owner must post this fresh, unedited exact comment:

```text
/repository-automation resume FULL_CURRENT_HEAD_SHA
```

The owner input retains compact original preparation provenance, including every
non-file byte and the original run, job, workflow, and artifact identities.
Published original review evidence retains that same input. After the native
artifact expires, the reader hydrates the two file payloads from the exact
reviewed Git head and verifies the reconstructed original artifact digest and
size. It never reruns historical native code. Inputs that exceed the bounded
owner context fail before review starts and require recovery of bounded original
evidence. Unpublished evidence without a recoverable original remains blocked.
