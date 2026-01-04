#!/usr/bin/env python3
"""
JamMonitor VPS - Metrics Collector and Historical Data Server

This script runs on your VPS to:
1. Pull metrics from your router every POLL_SECONDS
2. Store them in SQLite for long-term history
3. Serve historical data bundles to JamMonitor UI

Environment Variables:
    ROUTER_URL      - Full URL to router's metrics endpoint (required)
                      Example: http://100.x.x.x/cgi-bin/luci/jammonitor/metrics
    POLL_SECONDS    - How often to poll router (default: 5)
    RETENTION_DAYS  - How long to keep data (default: 30)
    PORT            - Server port (default: 8080)
    DB_PATH         - SQLite database path (default: ./jammonitor.db)

Usage:
    export ROUTER_URL="http://100.x.x.x/cgi-bin/luci/jammonitor/metrics"
    python3 jammonitor_vps.py

Or with systemd (see jammonitor-vps.service)
"""

import os
import sys
import json
import gzip
import sqlite3
import asyncio
import logging
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager

import aiohttp
import aiosqlite
from fastapi import FastAPI, Query, Response, HTTPException
from fastapi.middleware.cors import CORSMiddleware

# Configuration from environment
ROUTER_URL = os.getenv("ROUTER_URL")
POLL_SECONDS = int(os.getenv("POLL_SECONDS", "5"))
RETENTION_DAYS = int(os.getenv("RETENTION_DAYS", "30"))
PORT = int(os.getenv("PORT", "8080"))
DB_PATH = os.getenv("DB_PATH", "./jammonitor.db")

# Logging setup
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Global state
collector_task: Optional[asyncio.Task] = None
db_initialized = False


async def init_db():
    """Initialize SQLite database with metrics table"""
    global db_initialized
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute('''
            CREATE TABLE IF NOT EXISTS metrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp INTEGER NOT NULL,
                data TEXT NOT NULL,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        ''')
        await db.execute('CREATE INDEX IF NOT EXISTS idx_timestamp ON metrics(timestamp)')
        await db.commit()
    db_initialized = True
    logger.info(f"Database initialized at {DB_PATH}")


async def cleanup_old_data():
    """Delete records older than RETENTION_DAYS"""
    cutoff = int((datetime.utcnow() - timedelta(days=RETENTION_DAYS)).timestamp())
    async with aiosqlite.connect(DB_PATH) as db:
        cursor = await db.execute('DELETE FROM metrics WHERE timestamp < ?', (cutoff,))
        deleted = cursor.rowcount
        await db.commit()
    if deleted > 0:
        logger.info(f"Cleaned up {deleted} old records (older than {RETENTION_DAYS} days)")


async def collect_metrics():
    """Fetch metrics from router and store in database"""
    if not ROUTER_URL:
        return

    try:
        async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=10)) as session:
            async with session.get(ROUTER_URL) as response:
                if response.status == 200:
                    data = await response.json()
                    timestamp = data.get('timestamp', int(datetime.utcnow().timestamp()))

                    async with aiosqlite.connect(DB_PATH) as db:
                        await db.execute(
                            'INSERT INTO metrics (timestamp, data) VALUES (?, ?)',
                            (timestamp, json.dumps(data))
                        )
                        await db.commit()
                elif response.status == 403:
                    logger.warning(f"Access denied (403) - check Tailscale connection")
                else:
                    logger.warning(f"Router returned status {response.status}")
    except aiohttp.ClientError as e:
        logger.warning(f"Failed to reach router: {e}")
    except Exception as e:
        logger.error(f"Collection error: {e}")


async def collector_loop():
    """Background loop that collects metrics every POLL_SECONDS"""
    logger.info(f"Starting collector: polling {ROUTER_URL} every {POLL_SECONDS}s")
    cleanup_counter = 0

    while True:
        await collect_metrics()

        # Run cleanup every hour (3600 / POLL_SECONDS iterations)
        cleanup_counter += 1
        if cleanup_counter >= (3600 // POLL_SECONDS):
            await cleanup_old_data()
            cleanup_counter = 0

        await asyncio.sleep(POLL_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown events"""
    global collector_task

    await init_db()

    # Start collector if ROUTER_URL is configured
    if ROUTER_URL:
        collector_task = asyncio.create_task(collector_loop())
        logger.info("Collector started")
    else:
        logger.warning("ROUTER_URL not set - collector disabled, server-only mode")

    yield

    # Shutdown
    if collector_task:
        collector_task.cancel()
        try:
            await collector_task
        except asyncio.CancelledError:
            pass
        logger.info("Collector stopped")


# FastAPI app
app = FastAPI(
    title="JamMonitor VPS",
    description="Historical metrics storage for JamMonitor",
    version="1.0.0",
    lifespan=lifespan
)

# Enable CORS for browser access
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/status")
async def get_status():
    """Health check and statistics"""
    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            'SELECT COUNT(*), MIN(timestamp), MAX(timestamp) FROM metrics'
        ) as cursor:
            row = await cursor.fetchone()

    return {
        "status": "ok",
        "sample_count": row[0] or 0,
        "oldest_timestamp": row[1],
        "newest_timestamp": row[2],
        "retention_days": RETENTION_DAYS,
        "poll_seconds": POLL_SECONDS,
        "router_url": ROUTER_URL or "not configured",
        "collector_running": collector_task is not None and not collector_task.done()
    }


@app.get("/metrics")
async def get_metrics(
    hours: int = Query(default=24, ge=1, le=720, description="Hours of history to fetch"),
    limit: int = Query(default=0, ge=0, le=100000, description="Max records (0=unlimited)")
):
    """Query historical metrics as JSON"""
    cutoff = int((datetime.utcnow() - timedelta(hours=hours)).timestamp())

    query = 'SELECT timestamp, data FROM metrics WHERE timestamp > ? ORDER BY timestamp'
    params = [cutoff]

    if limit > 0:
        query += ' LIMIT ?'
        params.append(limit)

    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(query, params) as cursor:
            rows = await cursor.fetchall()

    return {
        "hours": hours,
        "count": len(rows),
        "metrics": [json.loads(r[1]) for r in rows]
    }


@app.get("/bundle")
async def download_bundle(
    hours: int = Query(default=24, ge=1, le=720, description="Hours of history to include")
):
    """Download historical data as gzipped JSON bundle"""
    cutoff = int((datetime.utcnow() - timedelta(hours=hours)).timestamp())

    async with aiosqlite.connect(DB_PATH) as db:
        async with db.execute(
            'SELECT timestamp, data FROM metrics WHERE timestamp > ? ORDER BY timestamp',
            (cutoff,)
        ) as cursor:
            rows = await cursor.fetchall()

    bundle = {
        "generated_at": datetime.utcnow().isoformat(),
        "hours": hours,
        "sample_count": len(rows),
        "retention_days": RETENTION_DAYS,
        "metrics": [json.loads(r[1]) for r in rows]
    }

    content = gzip.compress(json.dumps(bundle, indent=2).encode())
    filename = f"jammonitor-history-{hours}h-{datetime.utcnow().strftime('%Y%m%d-%H%M%S')}.json.gz"

    return Response(
        content=content,
        media_type="application/gzip",
        headers={"Content-Disposition": f"attachment; filename={filename}"}
    )


if __name__ == "__main__":
    import uvicorn

    if not ROUTER_URL:
        logger.warning("=" * 60)
        logger.warning("ROUTER_URL not set!")
        logger.warning("Set it to enable metrics collection:")
        logger.warning("  export ROUTER_URL='http://100.x.x.x/cgi-bin/luci/jammonitor/metrics'")
        logger.warning("Running in server-only mode (no collection)")
        logger.warning("=" * 60)

    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
