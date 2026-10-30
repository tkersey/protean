# Native Kosmos producer compatibility fixture

This inventory and its original manifest/profile bytes come from disposable Git
commit `2b8ee91d09ee8c728574d997b3f127e92f4f41bd`, tree
`a828641ec3f18bee7f0ef4cfa726c7d308f8ffd1`. The native producer independently
verified the full Git archive, recomputed the Zig package identity, checked
coherence, and ran the public native consumer before retaining the inventory.
The source archive has 3,774,976 bytes and SHA-256
`a1ecf33292cc1eed106fbac2a7b77b66cd88f05282e51040d1526c5529e17e9b`.
The archive is not checked into this repository.

The frozen source is Kosmos 9.1.1 with the exact Horos 8.0.0 dependency from the
adjacent `horos` producer fixture. Its source remains identical to the earlier
native cross-repository fixture; this receipt additionally exposes manifest
facts parsed by the native producer. The earlier receipt is not overwritten.

This is unpublished compatibility evidence. It has no production release,
qualification run, review closeout, or valid attestation. It does not qualify
this implementation's final Git head or authorize production admission.
