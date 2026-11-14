import io
import json
from pathlib import Path

import pytest

from geoloader import handler as h

SAMPLES = Path(__file__).parent.parent / "samples"


class FakeS3:
    def __init__(self, objects):
        self.objects = objects

    def get_object(self, Bucket, Key):  # noqa: N803 - boto3 argument names
        return {"Body": io.BytesIO(self.objects[Key])}


class FakeConn:
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture
def loaded(monkeypatch):
    """Replace S3 and the database with fakes; return the list of load calls."""
    calls = []
    objects = {
        "in/valid.geojson": (SAMPLES / "valid.geojson").read_bytes(),
        "in/invalid.geojson": (SAMPLES / "invalid.geojson").read_bytes(),
        "in/my file.geojson": (SAMPLES / "valid.geojson").read_bytes(),
    }
    monkeypatch.setattr(h, "_s3", lambda: FakeS3(objects))
    monkeypatch.setattr(h.db, "connect", lambda: FakeConn())
    monkeypatch.setattr(
        h.db,
        "load_features",
        lambda conn, key, features: calls.append((key, len(features))) or len(features),
    )
    return calls


def s3_event(key, size=100):
    return {"Records": [{"s3": {"bucket": {"name": "b"}, "object": {"key": key, "size": size}}}]}


def log_events(capsys):
    return [json.loads(line)["event"] for line in capsys.readouterr().out.splitlines()]


def test_valid_file_is_loaded_and_logged(loaded, capsys):
    result = h.handler(s3_event("in/valid.geojson"))

    assert result == {
        "results": [{"key": "in/valid.geojson", "status": "loaded", "rows": 3, "stats": None}]
    }
    assert loaded == [("in/valid.geojson", 3)]
    assert log_events(capsys) == ["file_received", "file_valid", "file_loaded"]


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_loaded_file_is_measured_by_the_gdal_service(loaded, monkeypatch, capsys):
    requests = []

    def fake_urlopen(request, timeout):
        requests.append((request.full_url, request.get_method(), len(request.data)))
        return FakeResponse(json.dumps({"features": 3, "area_m2": 12.5}).encode())

    monkeypatch.setattr(h, "GDAL_SERVICE_URL", "http://gdal.internal:8080")
    monkeypatch.setattr(h.urllib.request, "urlopen", fake_urlopen)

    result = h.handler(s3_event("in/valid.geojson"))

    assert result["results"][0]["stats"] == {"features": 3, "area_m2": 12.5}
    assert requests[0][:2] == ("http://gdal.internal:8080/stats", "POST")
    assert log_events(capsys)[-1] == "file_stats"


def test_gdal_service_outage_does_not_fail_the_load(loaded, monkeypatch, capsys):
    def unreachable(request, timeout):
        raise OSError("connection refused")

    monkeypatch.setattr(h, "GDAL_SERVICE_URL", "http://gdal.internal:8080")
    monkeypatch.setattr(h.urllib.request, "urlopen", unreachable)

    result = h.handler(s3_event("in/valid.geojson"))

    assert result["results"][0]["status"] == "loaded"
    assert result["results"][0]["stats"] is None
    assert log_events(capsys)[-1] == "stats_unavailable"


def test_invalid_file_is_rejected_and_not_loaded(loaded, capsys):
    result = h.handler(s3_event("in/invalid.geojson"))

    assert result["results"][0]["status"] == "rejected"
    assert "closed" in result["results"][0]["reason"]
    assert loaded == []
    assert log_events(capsys) == ["file_received", "file_rejected"]


def test_url_encoded_key_is_decoded(loaded):
    h.handler(s3_event("in/my+file.geojson"))
    assert loaded == [("in/my file.geojson", 3)]


def test_oversized_file_is_rejected_without_download(loaded, monkeypatch):
    monkeypatch.setattr(h, "MAX_FILE_BYTES", 10)
    result = h.handler(s3_event("in/valid.geojson", size=11))
    assert result["results"][0]["status"] == "rejected"
    assert loaded == []


def test_database_error_is_raised_so_lambda_retries(loaded, monkeypatch, capsys):
    def boom(conn, key, features):
        raise RuntimeError("db down")

    monkeypatch.setattr(h.db, "load_features", boom)
    with pytest.raises(RuntimeError, match="db down"):
        h.handler(s3_event("in/valid.geojson"))
    assert log_events(capsys)[-1] == "load_failed"


def test_init_db_action(monkeypatch):
    monkeypatch.setattr(h.db, "connect", lambda: FakeConn())
    monkeypatch.setattr(h.db, "ensure_schema", lambda conn: "3.5")
    assert h.handler({"action": "init_db"}) == {
        "status": "ok",
        "version": h.VERSION,
        "postgis_version": "3.5",
    }
