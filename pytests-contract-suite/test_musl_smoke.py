"""musl static-build smoke test, wrapped as a CI gate (see docs/agent-context.md: "Rust
CI also gates on a musl static build smoke-tested inside a minimal
(scratch/busybox-level) container"). Opt-in via PORTUALE_RUN_MUSL_SMOKE=1,
same pattern as test_benchmark_gate.py -- it needs podman or docker and
takes tens of seconds, so it stays out of the default fast contract-suite
run; CI should set the env var to actually enforce the gate.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "managers"))
import registry  # noqa: E402  (pmtest root is not a package)

pytestmark = pytest.mark.skipif(
    os.environ.get("PORTUALE_RUN_MUSL_SMOKE") != "1",
    reason="opt-in: set PORTUALE_RUN_MUSL_SMOKE=1 to run the musl container smoke test",
)


def _smoke_script():
    """`musl/smoke_test.sh` inside the active PM's own checkout.

    The script builds that tree's musl target, so it lives with the PM,
    not with the harness: it comes from the registry entry's `repo` like
    every other PM path."""
    try:
        _, pm = registry.active_pm()
        repo = registry.repo_dir(pm)
    except registry.RegistryError as exc:
        pytest.fail(str(exc))
    if repo is None:
        pytest.skip("the active PM has no `repo` in the registry: no musl build to smoke")
    script = repo / "musl" / "smoke_test.sh"
    if not script.is_file():
        pytest.skip(f"the active PM ships no musl smoke test ({script})")
    return script


def test_musl_static_binaries_run_in_scratch_container():
    if shutil.which("podman") is None and shutil.which("docker") is None:
        pytest.skip("neither podman nor docker available")
    result = subprocess.run(
        ["bash", str(_smoke_script())], capture_output=True, text=True, check=False
    )
    print(result.stdout)
    assert result.returncode == 0, result.stderr
