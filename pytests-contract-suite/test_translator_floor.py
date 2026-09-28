"""Unit tests for the upstream-resolver translator's EAPI floor helper.

`scripts/upstream_resolver_translate.py` raises playground ebuild and
installed EAPIs below the supported-range floor before constructing the
`ResolverPlayground` (backlog #220); `Capture._floor_eapi` is the pure
per-value step. Upstream passes EAPIs as ints (`"EAPI": 0`), as numeric
strings (`"EAPI": "4"`), omits the key entirely (implicit default 0,
which `_apply_floor` floors explicitly -- pinned here as the `None`
input), and uses suffixed EAPIs (`"7-hdepend"`) that must be left alone.
"""

import importlib.util
from pathlib import Path

_SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts" / "upstream_resolver_translate.py"
)


def _floor_eapi(value, floor):
    spec = importlib.util.spec_from_file_location(
        "upstream_resolver_translate", _SCRIPT
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Capture._floor_eapi(value, floor)


def test_floor_eapi_int_below_floor_is_raised():
    for value in (0, 4, 6, 7):
        new_value, changed = _floor_eapi(value, 8)
        assert (new_value, changed) == ("8", True)
    assert isinstance(_floor_eapi(0, 8)[0], str)


def test_floor_eapi_int_at_or_above_floor_is_kept():
    assert _floor_eapi(8, 8) == (8, False)
    assert _floor_eapi(9, 8) == (9, False)
    assert _floor_eapi(5, 7) == ("7", True)
    assert _floor_eapi(7, 7) == (7, False)


def test_floor_eapi_bool_is_not_an_int_eapi():
    # `isinstance(True, int)` holds, so the helper must exclude bools
    # explicitly rather than flooring `True` (= 1) to the floor.
    assert _floor_eapi(True, 8) == (True, False)
    assert _floor_eapi(False, 8) == (False, False)


def test_floor_eapi_str_below_floor_is_raised():
    for value in ("0", "4", "6"):
        assert _floor_eapi(value, 8) == ("8", True)


def test_floor_eapi_str_at_or_above_floor_is_kept():
    assert _floor_eapi("8", 8) == ("8", False)
    assert _floor_eapi("10", 8) == ("10", False)


def test_floor_eapi_missing_eapi_is_kept():
    # A missing EAPI arrives here as None (`_apply_floor` records the
    # floored default itself); the helper must not crash on it.
    assert _floor_eapi(None, 8) == (None, False)


def test_floor_eapi_suffixed_eapi_is_kept():
    for value in ("7-hdepend", "5-hdepend", "9-hdepend", "8-hdepend"):
        assert _floor_eapi(value, 8) == (value, False)


def test_floor_eapi_non_eapi_values_are_kept():
    assert _floor_eapi("", 8) == ("", False)
    assert _floor_eapi("abc", 8) == ("abc", False)
    assert _floor_eapi(4.0, 8) == (4.0, False)
    assert _floor_eapi(["8"], 8) == (["8"], False)
