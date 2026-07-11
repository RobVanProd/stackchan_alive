Import("env")

import csv
import os
import subprocess


def find_partition_offset(csv_path, name_candidates=("model", "srmodels", "esp_sr")):
    with open(csv_path, newline="") as csv_file:
        for row in csv.reader(csv_file):
            if not row or row[0].strip().startswith("#"):
                continue
            name = row[0].strip()
            if name in name_candidates:
                offset = row[3].strip()
                if not offset:
                    raise RuntimeError("Model partition offset is empty; set an explicit offset in the CSV.")
                return int(offset, 0)
    raise RuntimeError(f"Model partition not found in {csv_path}.")


def find_srmodels(project_dir):
    custom_path = env.GetProjectOption("custom_srmodels_path", None)
    if custom_path:
        candidate = custom_path
        if not os.path.isabs(candidate):
            candidate = os.path.join(project_dir, candidate)
        if os.path.exists(candidate):
            return candidate
        raise RuntimeError(f"custom_srmodels_path does not exist: {candidate}")

    candidates = (
        os.path.join(project_dir, "srmodels.bin"),
        os.path.join(project_dir, "data", "srmodels.bin"),
        os.path.join(project_dir, "output", "research", "ESP-SR-For-M5Unified",
                     "examples", "HiStackChanWakeUpWord_platformio", "srmodels.bin"),
    )
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    raise RuntimeError(
        "srmodels.bin not found. Copy the HiStackChan wake-word model to the project root "
        "or run the local research fetch before uploading stackchan_wake_sr_probe."
    )


def after_upload(source, target, env):
    project_dir = env["PROJECT_DIR"]
    partitions = env.BoardConfig().get("build.partitions", "partitions.csv")
    csv_path = os.path.join(project_dir, partitions)
    srmodels = find_srmodels(project_dir)
    offset = find_partition_offset(csv_path)
    port = env.subst("$UPLOAD_PORT")
    speed = env.subst("$UPLOAD_SPEED")
    chip = env.BoardConfig().get("build.mcu", "esp32s3")
    esptool = os.path.join(env.PioPlatform().get_package_dir("tool-esptoolpy"), "esptool.py")
    cmd = [
        env.subst("$PYTHONEXE"),
        esptool,
        "--chip",
        chip,
        "--port",
        port,
        "--baud",
        speed,
        "write_flash",
        hex(offset),
        srmodels,
    ]
    print("Flashing srmodels:", " ".join(cmd))
    subprocess.check_call(cmd)


env.AddPostAction("upload", after_upload)
