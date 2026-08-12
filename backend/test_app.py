from datetime import datetime

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
    # Rejected before get_db_connection() is ever called, so this needs no
    # real database - it's exercising the validation branch itself: items.name
    # is VARCHAR(255), and this should return a clean 400 instead of letting
    # Postgres's own truncation error leak through as a raw 500.
    client = app_module.app.test_client()
    resp = client.post("/api/items", json={"name": "x" * 256})
    assert resp.status_code == 400
    assert "255" in resp.get_json()["error"]
