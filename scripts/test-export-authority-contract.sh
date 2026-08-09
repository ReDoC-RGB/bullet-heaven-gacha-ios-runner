#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo/.github/workflows/build-ios-adhoc.yml"
runner="$repo/scripts/build-sign-return.sh"
authority="$repo/release-authority.json"
required=(BHG_EXPORT_MANIFEST_SHA256 BHG_EXPORT_INVENTORY_COUNT BHG_EXPORT_FRAMED_TREE_SHA256 BHG_CANDIDATE_COMMIT BHG_CANDIDATE_TREE)
for name in "${required[@]}"; do
  grep -Fq "$name" "$workflow" || { printf 'workflow missing exact authority input %s\n' "$name" >&2; exit 1; }
  grep -Fq "$name" "$runner" || { printf 'runner missing exact authority validation %s\n' "$name" >&2; exit 1; }
done
for stale in \
  44bab041101971978ab39fc7f56dd4a73e6344ee86583a9edc5bf5a4b28fa750 \
  1774dd6790a2189fbc913927bdfbbb6bd0fd9938 \
  a2b30d3bce97310dc3c6612833649360187e0dd4 \
  62740c60118f9867ac787baadfb8058f935ded317c9d8dc1b4f871bc010c68dd \
  486a64ce469a5e6c61564633ab43a3ce04a9d3aa78de62005063e471b5c75a6b \
  936aec62751d6b9fe183ca0875bdf37bfc1e8dfa557bbff479b2f88735ac09fd \
  fe4c8b2a6da3d582108851452975dd2cb6491c59 \
  3a963754b00a7f95f95912c48f627265543b2708 \
  3995f2ed4172b95852c87c7c8b56a8e0582761a228e217e113992a6fe9088caf \
  0f1630de0ca92672fb43c5efa8e8e77356e50e33b9b7c7f049800b1de9f5ca7d \
  6f4bcf79f86bcd802ba1cc4906b222f88c6091abc907722ed99f76b384a847e1 \
  ad95709b70c4f3db3c69ed243276a7ac8e55fcdb \
  46e1b04a870a5d2f8d3ecd167c9da4c035e2058f \
  "len(x['fileInventory'])==2996"; do
  if grep -Fq "$stale" "$runner"; then
    printf 'runner retains predecessor export authority: %s\n' "$stale" >&2
    exit 1
  fi
done
python3 - "$runner" "$authority" <<'PY'
import json
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
checks=[
 "x['candidateCommit']==os.environ['BHG_CANDIDATE_COMMIT']",
 "x['candidateTree']==os.environ['BHG_CANDIDATE_TREE']",
 "len(x['fileInventory'])==int(os.environ['BHG_EXPORT_INVENTORY_COUNT'])",
 "x['framedTreeSha256']==os.environ['BHG_EXPORT_FRAMED_TREE_SHA256']",
]
missing=[c for c in checks if c not in s]
if missing: raise SystemExit('missing fail-closed exact authority checks: '+repr(missing))
x=json.loads(Path(sys.argv[2]).read_text())
expected={
 'schema':1,
 'archiveSha256':'357a9c02ca942e3688d1a8e623bf8958233f6aeb02be301ef036a3a8e84d45ce',
 'manifestSha256':'c7417fa97776bd78c6bed57a1d558100827fc064370897d86383f21192fe23b4',
 'manifestByteLength':680938,
 'inventoryCount':3050,
 'framedTreeSha256':'d123b114b6b3cba3a2983afe4318847414de00f780df849835f716dfcbade881',
 'candidateCommit':'50750c7dec86da842401f635504aa1aca4b0ee2a',
 'candidateTree':'14833689a984708cda54603abf7da76d54f728d7',
}
if x!=expected: raise SystemExit('tracked final export authority mismatch')
for token in ['release-authority.json',"'archiveSha256':os.environ['BHG_EXPORT_SHA256']","'manifestSha256':os.environ['BHG_EXPORT_MANIFEST_SHA256']","'inventoryCount':int(os.environ['BHG_EXPORT_INVENTORY_COUNT'])","'candidateCommit':os.environ['BHG_CANDIDATE_COMMIT']"]:
 if token not in s: raise SystemExit('runner missing tracked authority binding: '+token)
PY
printf 'PASS exact export authority is tracked-commit-bound, protected-input-bound, and predecessor literals are absent\n'
