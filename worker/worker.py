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
AWS_ACCESS_KEY_ID = os.environ.get("AWS_ACCESS_KEY_ID", "") or None
AWS_SECRET_ACCESS_KEY = os.environ.get("AWS_SECRET_ACCESS_KEY", "") or None

# Polling interval in seconds
POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))


def get_db_connection():
    """Establish a connection to the PostgreSQL database."""
    return psycopg2.connect(
        host=DB_HOST,
        port=int(DB_PORT),
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD,
        connect_timeout=5,
    )


def publish_sns(subject: str, message: str):
    """Publish a message to the configured AWS SNS topic."""
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
    """Retrieve all database items with a 'pending' status."""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("""
            SELECT id, name, description, created_at
            FROM   items
            WHERE  status = 'pending'
            ORDER  BY created_at ASC;
        """)
        return [dict(row) for row in cur.fetchall()]


def mark_item_done(conn, item_id: int):
    """Update an item's status to 'done' and set the processing timestamp."""
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
    """Execute a single polling cycle to process pending items."""
    try:
        conn = get_db_connection()
    except Exception:
        logger.exception("Database connection failed. Retrying next cycle.")
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
            except Exception:
                logger.exception(f"Failed to process item ID {item['id']}")

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

    finally:
        conn.close()


def main():
    """Run the worker polling loop continuously."""
    logger.info("Worker service started.")
    logger.info(f"Target database: {DB_HOST}:{DB_PORT}/{DB_NAME}")
    logger.info(f"Polling interval: {POLL_INTERVAL_SECONDS} seconds.")

    while True:
        run_one_cycle()
        time.sleep(POLL_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
