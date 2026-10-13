"""
Creates the private key and certificate for the push job's JWT login.

  python generate_keys.py            -> keys/server.key (keep secret) and keys/server.crt (upload to Salesforce)

Upload server.crt to the External Client App ("Use digital signatures"). Never commit server.key;
the project's .gitignore excludes the keys folder.
"""
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID


def main(out_dir="keys", days=730):
    out = Path(out_dir)
    out.mkdir(exist_ok=True)
    key_path, crt_path = out / "server.key", out / "server.crt"
    if key_path.exists():
        print(f"{key_path} already exists; delete it first to create a new key.")
        return 1
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "trade-import-push-job")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=days)).sign(key, hashes.SHA256()))
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    crt_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    print(f"Created {key_path} (secret) and {crt_path} (upload to Salesforce). Certificate valid for {days} days.")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:2]))
