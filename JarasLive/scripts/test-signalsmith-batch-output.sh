#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
batch_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-spectral-batch.XXXXXX")"
trap 'rm -rf "$batch_test_dir"' EXIT
for variant in reference batch neutral; do
  options=()
  if [[ "$variant" != reference ]]; then options+=(-DCATLIVE_SIGNALSMITH_BATCH_OUTPUT=1); fi
  if [[ "$variant" == neutral ]]; then options+=(-DCATLIVE_SIGNALSMITH_NEUTRAL_SYNTHESIS=1); fi
  clang++ -std=c++17 -O2 "${options[@]+${options[@]}}" Tests/Apple/SignalsmithBatchOutputTests.cpp \
    -framework Accelerate -o "$batch_test_dir/$variant"
  "$batch_test_dir/$variant" > "$batch_test_dir/$variant.pcm"
done
cmp "$batch_test_dir/reference.pcm" "$batch_test_dir/batch.pcm"
python3 - "$batch_test_dir" <<'PY'
import array, pathlib, sys
folder=pathlib.Path(sys.argv[1])
reference=array.array('f', (folder/'reference.pcm').read_bytes())
neutral=array.array('f', (folder/'neutral.pcm').read_bytes())
assert len(reference)==len(neutral)
error=max(abs(a-b) for a,b in zip(reference, neutral))
assert error < 1e-6, error
print('SIGNALSMITH_NEUTRAL_SYNTHESIS_MAX_ERROR', error)
PY
echo SIGNALSMITH_BATCH_OUTPUT_BIT_EXACT_STEREO_SEEK_PITCH_RATE_OK
