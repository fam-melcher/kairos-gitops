# 0002 — Strategic merge patch for per-cluster overlay values

- Status: Accepted
- Date: 2026-07-24

## Context

Each app's per-cluster overlay (`clusters/<name>/apps/<app>/`, ADR 0001)
needs to supply the values its shared `base/<app>/` definition
deliberately omits — currently just the application version. Kustomize
supports two ways to express this kind of field-level override:
JSON6902 patches and strategic merge patches.

## Problem

Which patch type should per-cluster overlays use to override the small
number of fields (today: one) that are meant to differ from the shared
base?

## Considered Alternatives

1. **JSON6902** — addresses the target field by an exact structural path
   (e.g. `/spec/source/targetRevision`). Precise, but the path is
   positional: it has no way to identify "this field" independent of
   exactly where it sits in the document's structure. A base restructure
   that leaves the field itself untouched but changes where it lives can
   still break the patch.
2. **Strategic merge patch** — a partial YAML document matched to its
   target by resource identity (`apiVersion`/`kind`/`metadata.name`/
   `metadata.namespace`), merged into the base by field name rather than
   position. Chosen.

## Decision

Per-cluster overlays use a strategic merge patch file
(`version-patch.yaml`), referenced via `patches: - path:
version-patch.yaml` in the overlay's `kustomization.yaml`, rather than an
inline JSON6902 patch.

Verified locally: a full reorder of the base manifest's top-level and
`spec.source` fields did not break the strategic merge patch's ability to
supply `targetRevision` — the patch still applied correctly by matching
on the `Application`'s identity, not its structure.

## Consequences

- Overlay patch files read as plain YAML fragments, not JSON-pointer
  paths — no need to count structural depth to write or review one.
- The base can be reordered or restructured (as long as the target
  field's own name and nesting under `spec.source` stay the same)
  without needing to touch every overlay's patch.
- If a future override needs to *add* an item to a list rather than set a
  scalar field, JSON6902's `add`/array-index operations may be needed for
  that specific case — this decision applies to the scalar
  field-override case actually in use today, not as a blanket ban on
  JSON6902 elsewhere.

## Rationale

The one property that matters for this repo's overlays is that a base
restructure shouldn't silently break every cluster's patch. Strategic
merge patches get that by construction (identity-based matching); JSON6902
would require remembering to update every overlay's path expression in
lockstep with any base change instead.
