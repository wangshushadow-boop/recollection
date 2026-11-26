"""Verify native geometry across process restarts with an isolated Windows player profile."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output) as profile:
        appdata = Path(profile)
        env = os.environ | {"APPDATA": profile, "LOCALAPPDATA": profile, "RECOLLECTION_REMEMBER_WINDOW": "1"}
        env.pop("RECOLLECTION_WINDOW_DIR", None)
        for case in ("resize", "maximize", "minimize", "unmaximize", "override", "read", "clamp",
                     "shared-resize", "shared-read"):
            if case == "clamp":
                settings, = appdata.rglob("window.cfg")
                settings.write_text("[window]\nsize=Vector2i(20000, 20000)\nmaximized=false\n", encoding="utf-8")
            run_env = env | {"RECOLLECTION_WINDOW_CASE": case.removeprefix("shared-")}
            if case.startswith("shared-"):
                player_dir = appdata / case
                player_dir.mkdir()
                run_env.update(APPDATA=str(player_dir), LOCALAPPDATA=str(player_dir),
                               RECOLLECTION_WINDOW_DIR=str(appdata / "common-ui"))
            cmd = [str(args.godot.resolve()), "--path", str(args.project.resolve()), "--log-file", str(output / (case + ".log"))]
            if case == "override":
                run_env.pop("RECOLLECTION_REMEMBER_WINDOW")
                cmd += ["--resolution", "980x620"]
            cmd += ["--script", "res://tests/p2/window_preferences/run.gd", "--", "--profile=client"]
            result = subprocess.run(cmd, env=run_env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45)
            log = result.stdout + result.stderr
            lines = [line for line in log.splitlines() if line.startswith("WINDOW_PREF ")]
            if result.returncode or len(lines) != 1 or "ERROR:" in log or "failures=0" not in lines[0]:
                raise RuntimeError(case + "\n" + log)
            print(lines[0], flush=True)
        assert (appdata / "common-ui/window.cfg").is_file()
        assert not list((appdata / "shared-read").rglob("window.cfg"))


if __name__ == "__main__":
    main()
