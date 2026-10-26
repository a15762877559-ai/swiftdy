"""Evidence plumbing only; no Douyin requests and no credentials are read."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

SHA = "362dad3d082e9f63c8efd360acc653ba169d40a2"
ROOT = Path(__file__).resolve().parent.parent
SEEDS = ROOT / "evidence/doustudio-real-runtime-acceptance-01"


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def command(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "initialize"
    if mode == "initialize":
        root = Path(os.environ["RUNTIME_TEMP"]).resolve()
        evidence = root / "doustudio-runtime-evidence"
        media = root / "doustudio-runtime-media"
        evidence.mkdir(parents=True, exist_ok=True)
        for seed in SEEDS.glob("*.json"):
            shutil.copyfile(seed, evidence / seed.name)
        # Publish the evidence directory before validation, so invalid input
        # produces an artifact without initiating any platform request.
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
            stream.write(f"directory={evidence}\n")
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as stream:
            stream.write(f"EVIDENCE_DIR={evidence}\nMEDIA_DIR={media}\n")
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        inputs = event.get("inputs", {})
        profile = inputs.get("profile_url", "")
        consent = str(inputs.get("authorized_public_content", "false")).lower() == "true"
        valid = isinstance(profile, str) and re.fullmatch(r"https://www\.douyin\.com/user/[A-Za-z0-9_-]{1,256}", profile)
        if not consent or not valid:
            write(evidence / "failure-observations.json", {"observations": [{
                "phase": "input", "code": "EXPLICIT_CONSENT_AND_CANONICAL_PROFILE_REQUIRED", "classification": "BLOCKED"
            }]})
            print("Input blocked: enter a canonical public profile URL without query/fragment and confirm consent.")
            return 2
        print("::add-mask::" + profile)
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as stream:
            stream.write(f"PROFILE_URL={profile}\nRUNTIME_CONSENT=true\n")
        return 0
    evidence = Path(os.environ["EVIDENCE_DIR"])
    if mode == "environment":
        actual = command("git", "-C", str(ROOT / "upstream"), "rev-parse", "HEAD")
        if actual != SHA:
            return 1
        write(evidence / "runtime-environment.json", {
            "phase": "CLOUD_RUNTIME", "status": "PASS", "upstream_commit": actual,
            "macos": command("sw_vers"), "swift": command("swift", "--version"),
            "xcode": command("xcodebuild", "-version"), "architecture": command("uname", "-m"),
            "runner_label": "xcode-27", "run_id": os.environ["GITHUB_RUN_ID"],
            "test_repository_commit": os.environ["GITHUB_SHA"]
        })
    elif mode == "finalize":
        outcomes = {name: os.environ.get(name, "unknown") for name in (
            "INIT_OUTCOME", "ENVIRONMENT_OUTCOME", "COMPILE_OUTCOME", "SELFTEST_OUTCOME", "ACCEPTANCE_OUTCOME")}
        write(evidence / "stage-outcomes.json", outcomes)
        final = json.loads((evidence / "final-acceptance.json").read_text(encoding="utf-8"))
        if final["phase"] != "REAL_RUNTIME":
            # A failed build never becomes a runtime PASS/FAIL claim.
            final["phase"] = "CLOUD_PRE_RUNTIME_STOP"
            final["stop_reason"] = "INPUT_ENVIRONMENT_OR_HARNESS_DID_NOT_COMPLETE"
            write(evidence / "final-acceptance.json", final)
        original_clean = not command("git", "-C", str(ROOT / "upstream"), "status", "--porcelain", "--untracked-files=no") if (ROOT / "upstream/.git").exists() else None
        if original_clean is False:
            final["statuses"]["UPSTREAM_SOURCE_CHANGED"] = "YES"
            write(evidence / "final-acceptance.json", final)
            return 1
    elif mode == "cleanup":
        # Validate the exact target before any recursive delete.
        media = Path(os.environ["MEDIA_DIR"]).resolve()
        expected = Path(os.environ["RUNNER_TEMP"]).resolve() / "doustudio-runtime-media"
        if media != expected or media == media.parent:
            raise ValueError("Unexpected cleanup path")
        if media.exists():
            shutil.rmtree(media)
    else:
        raise ValueError("Unknown mode")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
