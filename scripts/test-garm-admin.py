#!/usr/bin/env python3
"""Exercise sync interruption and safe resumption without live credentials."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location("garm_admin", Path(__file__).resolve().parents[1] / "hosts/warbler/garm-admin.py")
garm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(garm)


class SyncTests(unittest.TestCase):
    def test_authentication_and_service_errors_stop_the_batch(self):
        for status in (401, 403, 429, 500, 503):
            with self.subTest(status=status):
                calls = []
                def request(method, path, data=None, token=None, **kwargs):
                    calls.append((method, path))
                    if method == "GET":
                        return []
                    if path == "/repositories":
                        return {"id": "fixture-id"}
                    raise HTTPError("http://localhost/fixture", status, "fixture", {}, io.BytesIO(b'{}'))
                with patch.dict(os.environ, {"GARM_SYNC_CREDENTIALS": "fixture", "GARM_SYNC_SCALE_SET": '{"name":"fixture"}'}), patch.object(garm, "installation_repositories", return_value={("example", "first"), ("example", "second")}), patch.object(garm, "request", side_effect=request), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        garm.sync_repos("fixture-token")
                self.assertEqual(calls.count(("POST", "/repositories")), 1)

    def test_next_run_reuses_completed_repository_registration(self):
        calls = []
        def request(method, path, data=None, token=None, **kwargs):
            calls.append((method, path))
            if path == "/repositories" and method == "GET":
                return [{"owner": "example", "name": "first", "id": "fixture-id", "credentials_name": "fixture"}]
            if method == "GET":
                return []
            self.assertEqual(kwargs.get("timeout"), garm.SLOW_TIMEOUT)
            return {}
        with patch.dict(os.environ, {"GARM_SYNC_CREDENTIALS": "fixture", "GARM_SYNC_SCALE_SET": '{"name":"fixture"}'}), patch.object(garm, "installation_repositories", return_value={("example", "first")}), patch.object(garm, "request", side_effect=request), contextlib.redirect_stdout(io.StringIO()):
            garm.sync_repos("fixture-token")
        self.assertNotIn(("POST", "/repositories"), calls)
        self.assertEqual(calls.count(("POST", "/repositories/fixture-id/scalesets")), 1)

    def test_installation_request_uses_bearer_authentication(self):
        with patch.object(garm, "urlopen", return_value=io.BytesIO(json.dumps({"ok": True}).encode())) as urlopen:
            self.assertEqual(garm.github("GET", "/fixture", "fixture-token"), {"ok": True})
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-token")
        self.assertEqual(request.get_header("User-agent"), "warbler-garm-repo-sync")


if __name__ == "__main__":
    unittest.main()
