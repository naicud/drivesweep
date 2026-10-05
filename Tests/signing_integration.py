"""Two changed builds must satisfy the same privacy authorization requirement."""
import pathlib
from contextlib import contextmanager
import plistlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr}")
    return result


@contextmanager
def signing_fixture():
    with tempfile.TemporaryDirectory(prefix="drivesweep-signing-") as temporary:
        directory = pathlib.Path(temporary)
        try:
            yield directory
        finally:
            for keychain in directory.glob("*/identity.keychain-db"):
                run("/usr/bin/security", "delete-keychain", str(keychain))


class SigningRegression(unittest.TestCase):
    def test_changed_build_keeps_authorization_identity(self):
        with signing_fixture() as directory:
            app = directory / "DriveSweep.app"
            executable = app / "Contents/MacOS/DriveSweep"
            executable.parent.mkdir(parents=True)
            info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            source = directory / "probe.c"
            requirements = []
            for version in (1, 2):
                source.write_text(f"int main(void) {{ return {version}; }}\n")
                run("clang", "-o", str(executable), str(source))
                run("make", "--no-print-directory", "sign", f"APP={app}",
                    "SIGNING_MODE=local", f"SIGNING_DIR={directory / 'identity'}")
                run("codesign", "--verify", "--deep", "--strict", str(app))
                displayed = run("codesign", "-d", "-r-", str(app))
                requirement = displayed.stdout + displayed.stderr
                match = re.search(r"designated => (.+)", requirement)
                self.assertIsNotNone(match, requirement)
                requirements.append(match.group(1))
                if version == 1:
                    saved = requirements[0]
            self.assertEqual(requirements[0], requirements[1],
                             "Each rebuild invalidates the saved macOS privacy consent")
            self.assertNotIn("cdhash", requirements[1])
            # Verify the changed code against the requirement saved for the first build.
            run("codesign", "--verify", "--strict", "-R", "=" + saved, str(app))
            # Another certificate with the same bundle ID cannot reuse that consent.
            run("make", "--no-print-directory", "sign", f"APP={app}",
                "SIGNING_MODE=local", f"SIGNING_DIR={directory / 'other-identity'}")
            rejected = subprocess.run(("codesign", "--verify", "--strict", "-R", "=" + saved, str(app)),
                                      text=True, capture_output=True)
            self.assertNotEqual(rejected.returncode, 0, "Consent must stay bound to the certificate")


if __name__ == "__main__":
    unittest.main()
