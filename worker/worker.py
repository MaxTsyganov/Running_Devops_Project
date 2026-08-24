"""
Background service that polls the database for pending tasks,
processes them, and sends SNS notifications upon completion.
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
from prometheus_client import Counter, Histogram, Gauge, start_http_server

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s - %(message)s",
)
logger = logging.getLogger("worker")

# Database Configuration
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ.get("DB_NAME", "appdb")
DB_USER = os.environ.get("DB_USER", "postgres")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "changeme")

# AWS Configuration
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")

# Normally unset in Kubernetes: the pod's IAM role (IRSA) supplies credentials
# automatically through boto3's default credential chain. These only matter
# when running outside the cluster with manually exported AWS keys.
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "") or None
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "") or None

POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))

# Heartbeat file used by Kubernetes readiness/liveness probes (worker has no HTTP port)
HEARTBEAT_FILE = os.environ.get("HEARTBEAT_FILE", "/tmp/worker_heartbeat")

# Same as backend/app.py - the exact commit CD deployed, not derived at runtime.
RELEASE_VERSION = os.environ.get("RELEASE_VERSION", "unknown")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "9100"))

# --- Prometheus metrics (Assignment 5) ---------------------------------
# git_sha on every metric, not just app_info - same reasoning as
# backend/app.py's own metrics: the dashboards' $version variable filters
# directly on this label (e.g. worker_items_processed_total{git_sha=~"$version"}),
# which only works if the label actually exists on the series. A fixed
# constant for this process's lifetime, so it costs nothing in cardinality.
ITEMS_PROCESSED_TOTAL = Counter(
    "worker_items_processed_total", "Total items successfully processed",
    ["git_sha"],
)
POLL_DURATION_SECONDS = Histogram(
    "worker_poll_duration_seconds", "Duration of one poll cycle in seconds",
    ["git_sha"],
)
POLL_ERRORS_TOTAL = Counter(
    "worker_poll_errors_total", "Total poll cycles that raised an exception",
    ["git_sha"],
)
LAST_POLL_TIMESTAMP_SECONDS = Gauge(
    "worker_last_poll_timestamp_seconds", "Unix time of the most recently completed poll cycle",
    ["git_sha"],
)
APP_INFO = Gauge(
    "app_info", "Static build/release info for this running process",
    ["version", "git_sha", "release"],
)
APP_INFO.labels(version=RELEASE_VERSION, git_sha=RELEASE_VERSION, release=RELEASE_VERSION).set(1)


def touch_heartbeat():
    """Update the heartbeat file's mtime so probes can detect a stuck loop."""
    with open(HEARTBEAT_FILE, "a"):
        os.utime(HEARTBEAT_FILE, None)


def get_db_connection():
    return psycopg2.connect(
        host=DB_HOST,
        port=int(DB_PORT),
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def publish_sns(subject: str, message: str):
    if not SNS_TOPIC_ARN:
        logger.warning("SNS topic missing. Notification skipped.")
        return
    try:
        sns = boto3.client(
            "sns",
            region_name=AWS_REGION,
            aws_access_key_id=AWS_ACCESS_KEY_ID,
            aws_secret_access_key=AWS_SECRET_ACCESS_KEY,
        )
        resp = sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject,
            Message=message,
        )
        logger.info(f"Notification sent. Message ID: {resp['MessageId']}")
    except ClientError:
        logger.exception("Failed to send notification")


def fetch_pending_items(conn) -> list[dict]:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, name, description, created_at
            FROM   items
            WHERE  status = 'pending'
            ORDER  BY created_at ASC;
        """)
        return [dict(row) for row in cur.fetchall()]


def mark_item_done(conn, item_id: int):
    with conn.cursor() as cur:
        cur.execute("""
            UPDATE items
            SET    status       = 'done',
                   processed_at = CURRENT_TIMESTAMP
            WHERE  id = %s;
        """, (item_id,))
    conn.commit()


def process_item(item: dict):
    """Simulate task processing."""
    logger.info(f"Processing item ID {item['id']} ('{item['name']}')...")
    time.sleep(0.5)
    logger.info(f"Item ID {item['id']} processed.")


def run_one_cycle():
    try:
        conn = get_db_connection()
    except Exception:
        logger.exception("Database connection failed. Retrying next cycle.")
        POLL_ERRORS_TOTAL.labels(git_sha=RELEASE_VERSION).inc()
        return

    try:
        pending = fetch_pending_items(conn)

        if not pending:
            logger.info("No pending items found.")
            return

        logger.info(f"Found {len(pending)} pending item(s).")
        processed_names = []

        for item in pending:
            try:
                process_item(item)
                mark_item_done(conn, item["id"])
                processed_names.append(item["name"])
                ITEMS_PROCESSED_TOTAL.labels(git_sha=RELEASE_VERSION).inc()
            except Exception:
                logger.exception(f"Failed to process item ID {item['id']}")
                POLL_ERRORS_TOTAL.labels(git_sha=RELEASE_VERSION).inc()

        if processed_names:
            count = len(processed_names)
            names_list = "\n".join(f"  - {n}" for n in processed_names)
            publish_sns(
                subject=f"[Worker] {count} item(s) processed",
                message=(
                    f"Worker finished processing {count} item(s).\n\n"
                    f"Items:\n{names_list}\n\n"
                    f"Completed at: {datetime.utcnow().isoformat()}Z\n"
                ),
            )

    except Exception:
        # Covers fetch_pending_items and publish_sns - e.g. the items table
        # not existing yet if this pod's first cycle races backend's startup
        # (backend creates the table, worker doesn't). Log and retry next
        # cycle instead of crashing over what's usually transient.
        logger.exception("Poll cycle failed")
        POLL_ERRORS_TOTAL.labels(git_sha=RELEASE_VERSION).inc()
    finally:
        conn.close()


def main():
    logger.info("Worker service started.")
    logger.info(f"Target database: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    logger.info(f"Polling interval: {POLL_INTERVAL_SECONDS} seconds.")

    # Worker's first-ever open port - a tiny built-in HTTP server just for
    # /metrics, nothing else (prometheus_client's own start_http_server,
    # not a real app server). Started once, before the loop, not per-cycle.
    start_http_server(METRICS_PORT)
    logger.info(f"Metrics server listening on :{METRICS_PORT}/metrics")

    touch_heartbeat()
    while True:
        with POLL_DURATION_SECONDS.labels(git_sha=RELEASE_VERSION).time():
            run_one_cycle()
        LAST_POLL_TIMESTAMP_SECONDS.labels(git_sha=RELEASE_VERSION).set_to_current_time()
        touch_heartbeat()
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
