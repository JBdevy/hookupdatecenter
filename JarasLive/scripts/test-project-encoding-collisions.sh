#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
encoder_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-encoding-review.XXXXXX")"
trap 'rm -rf "$encoder_test_dir"' EXIT
python3 - "$encoder_test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Application/Project/ProjectDocumentCodec.swift').read_text()
# Extract only the JSON helper; encryption constants never enter this fixture.
helper = source[source.index('enum ProjectDocumentJSON {'):]
helper = helper.replace('Key(hash: hasher.finalize(), count: values.count)', 'Key(hash: 0, count: values.count)')
helper = helper.replace('maximumCachedBytes = 16 * 1_048_576', 'maximumCachedBytes = 128')
helper = helper.replace('maximumCachedArrays = 1024', 'maximumCachedArrays = 2')
helper = helper.replace('            output.append(data)', '''            FixtureCounters.maximumBytes = max(FixtureCounters.maximumBytes, cachedBytes)
            FixtureCounters.maximumArrays = max(FixtureCounters.maximumArrays, cachedArrays)
            output.append(data)''')
fallback = helper.replace('enum ProjectDocumentJSON {', 'enum ProjectDocumentJSONSchemaFallback {').replace('case (.project, "songs"):', 'case (.project, "futureSongsKey"):')
(folder/'encoder.swift').write_text('import Foundation\n' + helper + '\n' + fallback)
(folder/'main.swift').write_text(Path('Tests/Apple/ProjectDocumentEncodingCollisionTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$encoder_test_dir/encoder.swift" "$encoder_test_dir/main.swift" -o "$encoder_test_dir/test"
"$encoder_test_dir/test"
