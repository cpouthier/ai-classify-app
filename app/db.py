import os
import psycopg2
import psycopg2.extras

POSTGRES_HOST = os.environ.get("POSTGRES_HOST", "postgres")
POSTGRES_DB = os.environ["POSTGRES_DB"]
POSTGRES_USER = os.environ["POSTGRES_USER"]
POSTGRES_PASSWORD = os.environ["POSTGRES_PASSWORD"]

SCHEMA = """
CREATE TABLE IF NOT EXISTS images (
    sequence_id SERIAL PRIMARY KEY,
    uuid UUID NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    label TEXT NOT NULL,
    confidence REAL NOT NULL,
    top3 JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    pod_name TEXT NOT NULL,
    node_name TEXT NOT NULL
);
"""


def get_connection():
    return psycopg2.connect(
        host=POSTGRES_HOST,
        dbname=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD,
    )


def init_schema():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(SCHEMA)
        conn.commit()


def insert_image(uuid, filename, label, confidence, top3, pod_name, node_name):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                INSERT INTO images (uuid, filename, label, confidence, top3, pod_name, node_name)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
                RETURNING sequence_id, uuid, filename, label, confidence, top3, created_at, pod_name, node_name
                """,
                (uuid, filename, label, confidence, psycopg2.extras.Json(top3), pod_name, node_name),
            )
            row = cur.fetchone()
        conn.commit()
    return row


def list_images(limit=200):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                """
                SELECT sequence_id, uuid, filename, label, confidence, top3, created_at, pod_name, node_name
                FROM images
                ORDER BY sequence_id DESC
                LIMIT %s
                """,
                (limit,),
            )
            return cur.fetchall()


def get_stats():
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT COUNT(*), COALESCE(MAX(sequence_id), 0) FROM images")
            total, last_sequence_id = cur.fetchone()
    return {"total_images": total, "last_sequence_id": last_sequence_id}


def get_image_row(image_uuid):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT filename FROM images WHERE uuid = %s", (image_uuid,))
            return cur.fetchone()


def delete_image(image_uuid):
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("DELETE FROM images WHERE uuid = %s RETURNING filename", (image_uuid,))
            row = cur.fetchone()
        conn.commit()
    return row


def delete_all_images():
    with get_connection() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("DELETE FROM images RETURNING filename")
            rows = cur.fetchall()
        conn.commit()
    return rows
