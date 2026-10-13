"""Tests for the push job against a mocked Salesforce endpoint. Run: python -m unittest test_push_job.py"""
import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import requests

import push_job


class FakeResponse:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
        self.text = json.dumps(body) if isinstance(body, dict) else str(body)

    def json(self):
        if isinstance(self._body, dict):
            return self._body
        raise ValueError("not json")


class FakeSession:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def post(self, url, json=None, timeout=None, headers=None):
        self.calls.append({"url": url, "json": json, "headers": headers})
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


class PushJobTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.lake = Path(self.tmp.name)
        (self.lake / "inbox" / "barder").mkdir(parents=True)
        self.file = self.lake / "inbox" / "barder" / "trades.csv"
        self.file.write_bytes("Trade Dt,Amount\r\n09/13/2026,100\r\n".encode("utf-8"))
        self.auth_calls = 0

    def tearDown(self):
        self.tmp.cleanup()

    def auth(self):
        self.auth_calls += 1
        return f"token{self.auth_calls}", "https://example.my.salesforce.com"

    def run_with(self, *responses):
        session = FakeSession(responses)
        counts = push_job.Pusher(self.auth, session=session, log=lambda *_: None).push_once(self.lake)
        return counts, session

    def test_payload_contents(self):
        payload = push_job.build_payload("BARDER", self.file)
        data = self.file.read_bytes()
        self.assertEqual(payload["fileHash"], hashlib.sha256(data).hexdigest())
        self.assertEqual(base64.b64decode(payload["content"]), data)
        self.assertEqual(payload["fileName"], "trades.csv")

    def test_created_moves_to_processed_with_upper_case_firm(self):
        counts, session = self.run_with(FakeResponse(201, {"batchId": "a0X", "status": "Received", "duplicate": False}))
        self.assertEqual(counts["sent"], 1)
        self.assertEqual(session.calls[0]["json"]["sourceFirm"], "BARDER")
        self.assertTrue(session.calls[0]["url"].endswith("/services/apexrest/trade-import/v1/files"))
        self.assertEqual(session.calls[0]["headers"]["Authorization"], "Bearer token1")
        self.assertFalse(self.file.exists())
        self.assertEqual(len(list((self.lake / "processed" / "BARDER").iterdir())), 1)

    def test_duplicate_is_counted_and_moved(self):
        counts, _ = self.run_with(FakeResponse(200, {"batchId": "a0X", "status": "Staged", "duplicate": True}))
        self.assertEqual(counts["duplicate"], 1)
        self.assertFalse(self.file.exists())

    def test_client_error_moves_to_failed_with_reason(self):
        counts, _ = self.run_with(FakeResponse(400, {"error": "sourceFirm is required."}))
        self.assertEqual(counts["failed"], 1)
        failed = list((self.lake / "failed" / "BARDER").iterdir())
        notes = [p for p in failed if p.name.endswith(".error.txt")]
        self.assertEqual(len(failed), 2)
        self.assertIn("sourceFirm is required", notes[0].read_text())

    def test_server_error_and_network_error_leave_file_for_retry(self):
        counts, _ = self.run_with(FakeResponse(500, "oops"))
        self.assertEqual(counts["retry"], 1)
        self.assertTrue(self.file.exists())
        counts, _ = self.run_with(requests.ConnectionError("down"))
        self.assertEqual(counts["retry"], 1)
        self.assertTrue(self.file.exists())

    def test_expired_token_reauthenticates_once(self):
        counts, session = self.run_with(FakeResponse(401, {"error": "expired"}),
                                        FakeResponse(201, {"batchId": "a0X", "status": "Received"}))
        self.assertEqual(counts["sent"], 1)
        self.assertEqual(self.auth_calls, 2)
        self.assertEqual(session.calls[1]["headers"]["Authorization"], "Bearer token2")

    def test_ignores_non_csv_files_and_loose_files(self):
        (self.lake / "inbox" / "barder" / "readme.md").write_text("x")
        (self.lake / "inbox" / "loose.csv").write_text("x")
        self.assertEqual([p.name for _, p in push_job.pending_files(self.lake)], ["trades.csv"])

    def test_missing_inbox_is_empty(self):
        self.assertEqual(push_job.pending_files(self.lake / "nowhere"), [])

    def test_jwt_assertion_claims_and_token_exchange(self):
        import jwt
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.hazmat.primitives import serialization
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        key_file = self.lake / "server.key"
        key_file.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
        env = {"SF_CLIENT_ID": "consumer-key", "SF_USERNAME": "push@example.com", "SF_PRIVATE_KEY_FILE": str(key_file)}
        with mock.patch.object(push_job.requests, "post",
                               return_value=FakeResponse(200, {"access_token": "T", "instance_url": "https://x.my.salesforce.com/"})) as post:
            token, instance = push_job.auth_jwt(env)
        self.assertEqual((token, instance), ("T", "https://x.my.salesforce.com"))
        url = post.call_args.args[0]
        data = post.call_args.kwargs["data"]
        self.assertEqual(url, "https://login.salesforce.com/services/oauth2/token")
        self.assertEqual(data["grant_type"], "urn:ietf:params:oauth:grant-type:jwt-bearer")
        claims = jwt.decode(data["assertion"], key.public_key(), algorithms=["RS256"],
                            audience="https://login.salesforce.com")
        self.assertEqual((claims["iss"], claims["sub"]), ("consumer-key", "push@example.com"))

    def test_jwt_reports_missing_settings(self):
        with self.assertRaises(push_job.AuthError) as ctx:
            push_job.auth_jwt({})
        self.assertIn("SF_CLIENT_ID", str(ctx.exception))

    def test_sfcli_parses_org_display(self):
        out = json.dumps({"result": {"accessToken": "AT", "instanceUrl": "https://y.my.salesforce.com/"}})
        with mock.patch.object(push_job.shutil, "which", return_value="/usr/bin/sf"), \
             mock.patch.object(push_job.subprocess, "run", return_value=mock.Mock(stdout=out, stderr="")):
            self.assertEqual(push_job.auth_sfcli("tradeDemo"), ("AT", "https://y.my.salesforce.com"))
        with mock.patch.object(push_job.shutil, "which", return_value=None):
            with self.assertRaises(push_job.AuthError):
                push_job.auth_sfcli("tradeDemo")


if __name__ == "__main__":
    unittest.main()
