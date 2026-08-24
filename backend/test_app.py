from datetime import datetime
from io import BytesIO

import app as app_module


def test_row_to_dict_converts_datetime_to_isoformat():
    row = {"id": 1, "name": "test", "created_at": datetime(2026, 1, 1, 12, 0, 0)}
    result = app_module._row_to_dict(row)
    assert result["created_at"] == "2026-01-01T12:00:00"
    assert result["id"] == 1
    assert result["name"] == "test"


def test_row_to_dict_leaves_non_datetime_values_untouched():
    row = {"id": 2, "name": "test", "created_at": None}
    result = app_module._row_to_dict(row)
    assert result["created_at"] is None


def test_healthz_does_not_touch_the_database():
    client = app_module.app.test_client()
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "alive"}


def test_create_item_rejects_name_over_255_chars():
    # No real database needed - rejected before get_db_connection() is
    # called. This exercises the validation branch: items.name is
    # VARCHAR(255), so we return a clean 400 instead of letting Postgres's
    # truncation error leak through as a raw 500.
    client = app_module.app.test_client()
    resp = client.post("/api/items", json={"name": "x" * 256})
    assert resp.status_code == 400
    assert "255" in resp.get_json()["error"]


def test_create_item_rejects_missing_name():
    client = app_module.app.test_client()
    resp = client.post("/api/items", json={})
    assert resp.status_code == 400
    assert "required" in resp.get_json()["error"].lower()


def test_create_item_rejects_whitespace_only_name():
    client = app_module.app.test_client()
    resp = client.post("/api/items", json={"name": "   "})
    assert resp.status_code == 400
    assert "required" in resp.get_json()["error"].lower()


def test_upload_rejects_request_without_file_field():
    # No S3 bucket config or real upload needed - rejected before
    # S3_BUCKET_NAME is even checked.
    client = app_module.app.test_client()
    resp = client.post("/api/upload", data={})
    assert resp.status_code == 400
    assert "no file" in resp.get_json()["error"].lower()


def test_upload_rejects_empty_filename():
    client = app_module.app.test_client()
    resp = client.post(
        "/api/upload",
        data={"file": (BytesIO(b"data"), "")},
        content_type="multipart/form-data",
    )
    assert resp.status_code == 400
    assert "name" in resp.get_json()["error"].lower()
