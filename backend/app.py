"""
Backend API service for managing database records,
handling S3 file uploads, and triggering SNS alerts.
"""

import os
import logging
from datetime import datetime

import boto3
import psycopg2
import psycopg2.extras
from botocore.exceptions import ClientError
from dotenv import load_dotenv
from flask import Flask, jsonify, request
from flask_cors import CORS

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

# Normally unset in Kubernetes: the pod's IAM role (IRSA) supplies credentials
# automatically through boto3's default credential chain. These only matter
# when running outside the cluster with manually exported AWS keys.
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "") or None
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "") or None


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
    # Liveness only: confirms the process can serve a request, nothing more.
    # A transient RDS outage should mark the pod not-ready (via /api/health,
    # used by readinessProbe) rather than get it killed and restarted
    # (livenessProbe's job) - the process itself isn't what's stuck.
    return jsonify({"status": "alive"}), 200


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
        return jsonify({"error": str(exc)}), 500
    finally:
        if conn:
            conn.close()

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
