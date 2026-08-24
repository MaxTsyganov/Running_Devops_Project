"""
Backend API service for managing database records,
handling S3 file uploads, and triggering SNS alerts.
"""

import os
import time
import logging
from datetime import datetime

import boto3
import psycopg2
import psycopg2.extras
from botocore.exceptions import ClientError
from dotenv import load_dotenv
from flask import Flask, jsonify, request, g, abort, Response
from flask_cors import CORS
from prometheus_client import Counter, Histogram, Gauge, generate_latest, CONTENT_TYPE_LATEST

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("backend")

app = Flask(__name__)
CORS(app)

# Database Configuration
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "changeme")

# AWS Configuration
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
S3_BUCKET_NAME = os.environ.get("S3_BUCKET_NAME", "")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

# Unset in Kubernetes - IRSA supplies credentials via boto3's default chain.
# Only needed when running outside the cluster with exported AWS keys.
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "") or None
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "") or None

# Full commit SHA, set by Jenkins CD at deploy time - lets app_info report
# exactly what was deployed.
RELEASE_VERSION = os.environ.get("RELEASE_VERSION", "unknown")

# --- Prometheus metrics (Assignment 5) ---------------------------------
# path label uses the Flask route pattern (request.url_rule.rule), never the
# raw URL, to keep cardinality bounded if a path-parameter route is added later.
#
# git_sha is duplicated on every metric (not just app_info) so dashboard
# panels can filter directly on it without a join.
HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total", "Total HTTP requests",
    ["method", "path", "status", "git_sha"],
)
HTTP_REQUEST_DURATION_SECONDS = Histogram(
    "http_request_duration_seconds", "HTTP request duration in seconds",
    ["method", "path", "git_sha"],
)
# Standard Prometheus "info" pattern: value is always 1, labels carry the data.
APP_INFO = Gauge(
    "app_info", "Static build/release info for this running process",
    ["version", "git_sha", "release"],
)
APP_INFO.labels(version=RELEASE_VERSION, git_sha=RELEASE_VERSION, release=RELEASE_VERSION).set(1)
# Required business metric - a real user action, not an infra signal.
ITEMS_CREATED_TOTAL = Counter(
    "items_created_total", "Total items successfully created via POST /api/items",
    ["git_sha"],
)
# Tracks which downstream dependency failed (rds/s3/sns), distinct from the
# generic http_requests_total{status=500}.
DEPENDENCY_FAILURES_TOTAL = Counter(
    "dependency_call_failures_total", "Total failed calls to an external dependency",
    ["dependency", "git_sha"],
)
# Excluded so probe/scrape traffic doesn't dominate rate/latency panels.
_METRICS_EXCLUDED_PATHS = {"/metrics", "/healthz", "/api/health"}


@app.before_request
def _start_request_timer():
    g._request_start_time = time.time()


@app.after_request
def _record_request_metrics(response):
    if request.path not in _METRICS_EXCLUDED_PATHS:
        path = request.url_rule.rule if request.url_rule else "unmatched"
        duration = time.time() - g.get("_request_start_time", time.time())
        HTTP_REQUESTS_TOTAL.labels(
            method=request.method, path=path, status=response.status_code,
            git_sha=RELEASE_VERSION,
        ).inc()
        HTTP_REQUEST_DURATION_SECONDS.labels(
            method=request.method, path=path, git_sha=RELEASE_VERSION,
        ).observe(duration)
    return response


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=int(DB_PORT),
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def init_db():
    conn = get_db_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS items (
                    id           SERIAL       PRIMARY KEY,
                    name         VARCHAR(255) NOT NULL,
                    description  TEXT         DEFAULT '',
                    status       VARCHAR(50)  DEFAULT 'pending',
                    created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
                    processed_at TIMESTAMP
                );
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS uploads (
                    id         SERIAL       PRIMARY KEY,
                    filename   VARCHAR(255) NOT NULL,
                    s3_key     VARCHAR(500) NOT NULL,
                    created_at TIMESTAMP    DEFAULT CURRENT_TIMESTAMP
                );
            """)
        conn.commit()
        logger.info("Database tables initialized successfully.")
    except Exception:
        conn.rollback()
        logger.exception("Database initialization failed")
        raise
    finally:
        conn.close()


def _aws_kwargs():
    """Return explicit AWS credentials if set, otherwise None so boto3 falls
    back to its default credential chain (IRSA in the cluster)."""
    return dict(
        region_name=AWS_REGION,
        aws_access_key_id=AWS_ACCESS_KEY_ID,
        aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
    )


def publish_sns(subject: str, message: str):
    if not SNS_TOPIC_ARN:
        logger.warning("SNS topic is missing. Notification skipped.")
        return
    try:
        sns = boto3.client("sns", **_aws_kwargs())
        resp = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message,
        )
        logger.info(
            f"Notification sent successfully. Message ID: {resp['MessageId']}")
    except ClientError:
        logger.exception("Failed to send notification")
        DEPENDENCY_FAILURES_TOTAL.labels(dependency="sns", git_sha=RELEASE_VERSION).inc()


def _row_to_dict(row: dict) -> dict:
    out = {}
    for k, v in row.items():
        out[k] = v.isoformat() if isinstance(v, datetime) else v
    return out


@app.get("/api/health")
def health():
    try:
        conn = get_db_connection()
        conn.close()
        return jsonify({"status": "ok", "db": "reachable"}), 200
    except Exception as exc:
        return jsonify({"status": "error", "detail": str(exc)}), 503


@app.get("/healthz")
def healthz():
    # Liveness only. DB health lives in /api/health (readinessProbe) so a
    # transient RDS outage marks the pod not-ready instead of killing it.
    return jsonify({"status": "alive"}), 200


@app.get("/metrics")
def metrics():
    # Scraped only by Prometheus via NetworkPolicy - see
    # helm/devops-app/templates/networkpolicies.yaml. Not proxied by nginx.
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.post("/api/debug/fail")
def debug_fail():
    # Controlled failure endpoint for the HighErrorRate alert drill - a real
    # request through the normal hooks, so it genuinely increments
    # http_requests_total{status=500}.
    abort(500)


@app.get("/api/items")
def list_items():
    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM items ORDER BY created_at DESC;")
            rows = cur.fetchall()
        return jsonify({"items": [_row_to_dict(r) for r in rows]}), 200
    except Exception as exc:
        logger.exception("Failed to fetch items")
        DEPENDENCY_FAILURES_TOTAL.labels(dependency="rds", git_sha=RELEASE_VERSION).inc()
        return jsonify({"error": str(exc)}), 500
    finally:
        if conn:
            conn.close()


@app.post("/api/items")
def create_item():
    body = request.get_json(silent=True) or {}
    name = (body.get("name") or "").strip()
    if not name:
        return jsonify({"error": "Name is required"}), 400
    if len(name) > 255:
        return jsonify({"error": "Name must be 255 characters or fewer"}), 400

    description = (body.get("description") or "").strip()

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO items (name, description)
                VALUES (%s, %s)
                RETURNING id, status, created_at;
                """,
                (name, description),
            )
            row_id, status, created_at = cur.fetchone()
        conn.commit()
        logger.info(f"Item created with ID {row_id}")
    except Exception as exc:
        logger.exception("Failed to save item to database")
        DEPENDENCY_FAILURES_TOTAL.labels(dependency="rds", git_sha=RELEASE_VERSION).inc()
        return jsonify({"error": str(exc)}), 500
    finally:
        if conn:
            conn.close()

    # Only incremented on a real, committed creation - not on the 400s
    # above, which never reach here.
    ITEMS_CREATED_TOTAL.labels(git_sha=RELEASE_VERSION).inc()

    publish_sns(
        subject=f"[App] New item created: {name}",
        message=(
            f"A new item was added to the database.\n\n"
            f"  ID          : {row_id}\n"
            f"  Name        : {name}\n"
            f"  Description : {description}\n"
            f"  Status      : {status}\n"
            f"  Created at  : {created_at.isoformat()}\n"
        ),
    )

    return jsonify({
        "id":          row_id,
        "name":        name,
        "description": description,
        "status":      status,
        "created_at":  created_at.isoformat(),
    }), 201


@app.post("/api/upload")
def upload_file():
    if "file" not in request.files:
        return jsonify({"error": "No file included in the request"}), 400

    f = request.files["file"]
    if not f.filename:
        return jsonify({"error": "File does not have a name"}), 400

    if not S3_BUCKET_NAME:
        return jsonify({"error": "S3 bucket name is missing"}), 500

    # Add a timestamp to the file name to prevent overwriting existing files
    ts = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
    s3_key = f"uploads/{ts}_{f.filename}"

    try:
        s3 = boto3.client("s3", **_aws_kwargs())
        s3.upload_fileobj(
            f,
            S3_BUCKET_NAME,
            s3_key,
            ExtraArgs={
                "ContentType": f.content_type or "application/octet-stream"},
        )
        logger.info(f"File uploaded to S3 successfully: {s3_key}")
    except ClientError:
        logger.exception("Failed to upload file to S3")
        DEPENDENCY_FAILURES_TOTAL.labels(dependency="s3", git_sha=RELEASE_VERSION).inc()
        return jsonify({"error": "S3 upload failed"}), 500

    conn = None
    try:
        conn = get_db_connection()
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO uploads (filename, s3_key) VALUES (%s, %s) RETURNING id;",
                (f.filename, s3_key),
            )
            upload_id = cur.fetchone()[0]
        conn.commit()
    except Exception as exc:
        logger.exception("Failed to save upload record in database")
        DEPENDENCY_FAILURES_TOTAL.labels(dependency="rds", git_sha=RELEASE_VERSION).inc()
        return jsonify({"error": str(exc)}), 500
    finally:
        if conn:
            conn.close()

    s3_url = f"https://{S3_BUCKET_NAME}.s3.{AWS_REGION}.amazonaws.com/{s3_key}"

    publish_sns(
        subject=f"[App] New file uploaded: {f.filename}",
        message=(
            f"A file was uploaded to S3.\n\n"
            f"  Upload ID   : {upload_id}\n"
            f"  Filename    : {f.filename}\n"
            f"  S3 location : s3://{S3_BUCKET_NAME}/{s3_key}\n"
            f"  URL         : {s3_url}\n"
            f"  Uploaded at : {datetime.utcnow().isoformat()}Z\n"
        ),
    )

    return jsonify({
        "id":       upload_id,
        "filename": f.filename,
        "s3_key":   s3_key,
        "s3_url":   s3_url,
    }), 201


if __name__ == "__main__":
    logger.info("Initializing database tables...")
    init_db()
    logger.info("Starting Flask application on port 5000...")
    app.run(host="0.0.0.0", port=5000, debug=False)
