#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$SCRIPT_DIR")}

# Apple supplies Git credentials for explicitly authorized dependencies.
# Never put a developer token or a local Mac path into this workflow.
python3 "$REPO_ROOT/scripts/prepare_cloud_reference_library.py" --repository "$REPO_ROOT"
python3 "$REPO_ROOT/scripts/test_capture_pipeline.py"
