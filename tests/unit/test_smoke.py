"""M0 gate: the Python suite runs and the package imports."""

import luantibot


def test_package_imports() -> None:
    assert luantibot.__version__
