"""Sign local builds with a persistent, certificate-bound identity.

The private identity stays outside the checkout in a dedicated user keychain.
No system trust settings or TCC records are changed.
"""
import argparse
import fcntl
import hashlib
import os
import pathlib
import plistlib
import secrets
import subprocess
import sys
import tempfile


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        # Never echo command arguments: keychain operations include credentials.
        raise RuntimeError(f"{pathlib.Path(args[0]).name}: {result.stderr.strip()}")
    return result.stdout.strip()


def local_identity(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    keychain = directory / "identity.keychain-db"
    password_file = directory / "keychain-password"
    certificate = directory / "certificate.der"
    if not keychain.exists():
        if password_file.exists() or certificate.exists():
            raise RuntimeError("Local signing identity is incomplete. Restore it from backup; "
                               "creating a new certificate would invalidate saved permissions.")
        password = secrets.token_hex(32)
        with tempfile.TemporaryDirectory(prefix="drivesweep-certificate-") as temporary:
            stage = pathlib.Path(temporary)
            configuration = stage / "certificate.cnf"
            configuration.write_text("""[req]
distinguished_name = subject
x509_extensions = extensions
prompt = no
[subject]
CN = DriveSweep Local Code Signing
[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
""")
            key = stage / "key.pem"
            pem = stage / "certificate.pem"
            bundle = stage / "identity.p12"
            run("openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-sha256", "-days", "3650", "-config", str(configuration),
                "-keyout", str(key), "-out", str(pem))
            run("openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(certificate))
            # Keychain import needs the legacy PKCS#12 algorithms on macOS.
            run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(pem),
                "-out", str(bundle), "-passout", f"pass:{password}")
            password_file.touch(mode=0o600)
            password_file.write_text(password)
            run("/usr/bin/security", "create-keychain", "-p", password, str(keychain))
            run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
            run("/usr/bin/security", "import", str(bundle), "-k", str(keychain),
                "-P", password, "-T", "/usr/bin/codesign")
            run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, str(keychain))
    if not password_file.is_file() or not certificate.is_file():
        raise RuntimeError("Local signing identity is incomplete; restore its files from backup.")
    password = password_file.read_text().strip()
    run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
    return keychain, fingerprint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("--mode", choices=("local", "identity", "adhoc"), default="local")
    parser.add_argument("--identity", default="")
    parser.add_argument("--directory", type=pathlib.Path,
                        default=pathlib.Path.home() / "Library/Application Support/DriveSweep/Signing")
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    identifier = info["CFBundleIdentifier"]
    command = ["/usr/bin/codesign", "--force", "--sign"]
    if args.mode == "local":
        args.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Concurrent builds must never create two different local certificates.
        with (args.directory / ".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            keychain, fingerprint = local_identity(args.directory)
        command += [fingerprint, "--keychain", str(keychain), "--timestamp=none",
                    "--requirements", f'=designated => identifier "{identifier}" and anchor = H"{fingerprint}"']
    elif args.mode == "identity":
        if not args.identity or args.identity == "-":
            raise RuntimeError("SIGNING_MODE=identity requires a certificate in SIGNING_IDENTITY.")
        command += [args.identity, "--options", "runtime", "--timestamp"]
    else:
        command += ["-"]
        print("Ad hoc signature: changed builds will require macOS privacy consent again.", file=sys.stderr)
    run(*command, str(args.app))
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.app))
    print(f"Signed {args.app.name} ({args.mode}).")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Signing failed: {error}", file=sys.stderr)
        sys.exit(1)
