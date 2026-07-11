Import("env")

import os


expected = "ERASE_STACKCHAN_64GB_MOVIES"
actual = os.environ.get("STACKCHAN_SD_FORMAT_BUILD_TOKEN", "")
if actual != expected:
    raise RuntimeError(
        "Refusing to build destructive SD provisioner. "
        "Set STACKCHAN_SD_FORMAT_BUILD_TOKEN=ERASE_STACKCHAN_64GB_MOVIES explicitly."
    )

env.Append(CPPDEFINES=[("STACKCHAN_SD_PROVISIONER", 1)])
