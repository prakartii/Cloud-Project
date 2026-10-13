import hashlib
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import psycopg
from fastapi import FastAPI, HTTPException, Query
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

log = logging.getLogger("library")

SCHEMA = (Path(__file__).parent / "schema.sql").read_text()
DATABASE_URL = os.environ["DATABASE_URL"]
FRONTEND_DIR = os.environ.get("FRONTEND_DIR", str(Path(__file__).resolve().parents[2] / "frontend"))

pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=8, kwargs={"row_factory": dict_row}, open=False)


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True, timeout=30)
    # Advisory lock so several workers/instances booting at once don't race on create/seed.
    with pool.connection() as conn:
        conn.execute("SELECT pg_advisory_xact_lock(424242)")
        conn.execute(SCHEMA)
    log.info("database ready")
    yield
    pool.close()


app = FastAPI(title="Library Management System", lifespan=lifespan)


class NewBook(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    author: str = Field(min_length=1, max_length=120)
    isbn: str | None = Field(default=None, max_length=20)
    copies: int = Field(default=1, ge=1, le=100)


class NewMember(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    email: str = Field(min_length=3, max_length=120, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class NewLoan(BaseModel):
    book_id: int
    member_id: int


@app.get("/health")
def health():
    try:
        with pool.connection() as conn:
            conn.execute("SELECT 1")
    except Exception:
        raise HTTPException(503, "database unavailable")
    return {"status": "ok"}


@app.get("/api/info")
def info():
    return {
        "instance_id": os.environ.get("INSTANCE_ID", "local"),
        "availability_zone": os.environ.get("AVAILABILITY_ZONE", "local"),
    }


@app.get("/api/books")
def list_books():
    with pool.connection() as conn:
        return conn.execute(
            "SELECT id, title, author, isbn, copies_total, copies_available FROM books ORDER BY id"
        ).fetchall()


@app.post("/api/books", status_code=201)
def add_book(b: NewBook):
    try:
        with pool.connection() as conn:
            return conn.execute(
                "INSERT INTO books (title, author, isbn, copies_total, copies_available) "
                "VALUES (%s, %s, %s, %s, %s) "
                "RETURNING id, title, author, isbn, copies_total, copies_available",
                (b.title.strip(), b.author.strip(), (b.isbn or "").strip() or None, b.copies, b.copies),
            ).fetchone()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, "a book with this ISBN already exists")


@app.get("/api/members")
def list_members():
    with pool.connection() as conn:
        return conn.execute("SELECT id, name, email FROM members ORDER BY id").fetchall()


@app.post("/api/members", status_code=201)
def add_member(m: NewMember):
    try:
        with pool.connection() as conn:
            return conn.execute(
                "INSERT INTO members (name, email) VALUES (%s, %s) RETURNING id, name, email",
                (m.name.strip(), m.email.strip().lower()),
            ).fetchone()
    except psycopg.errors.UniqueViolation:
        raise HTTPException(409, "a member with this email already exists")


LOAN_SELECT = (
    "SELECT l.id, b.title AS book_title, m.name AS member_name, l.issued_at, l.due_at, l.returned_at "
    "FROM loans l JOIN books b ON b.id = l.book_id JOIN members m ON m.id = l.member_id"
)


@app.get("/api/loans")
def list_loans():
    with pool.connection() as conn:
        return conn.execute(LOAN_SELECT + " ORDER BY l.id DESC LIMIT 50").fetchall()


@app.post("/api/loans", status_code=201)
def issue_loan(l: NewLoan):
    try:
        with pool.connection() as conn:
            # Atomic check-and-decrement: no two requests can take the last copy.
            taken = conn.execute(
                "UPDATE books SET copies_available = copies_available - 1 "
                "WHERE id = %s AND copies_available > 0 RETURNING id",
                (l.book_id,),
            ).fetchone()
            if not taken:
                exists = conn.execute("SELECT 1 FROM books WHERE id = %s", (l.book_id,)).fetchone()
                raise HTTPException(409 if exists else 404, "no copies available" if exists else "unknown book")
            loan_id = conn.execute(
                "INSERT INTO loans (book_id, member_id) VALUES (%s, %s) RETURNING id",
                (l.book_id, l.member_id),
            ).fetchone()["id"]
            return conn.execute(LOAN_SELECT + " WHERE l.id = %s", (loan_id,)).fetchone()
    except psycopg.errors.ForeignKeyViolation:
        raise HTTPException(404, "unknown member")  # the transaction (and the decrement) is rolled back


@app.post("/api/loans/{loan_id}/return")
def return_loan(loan_id: int):
    with pool.connection() as conn:
        row = conn.execute(
            "UPDATE loans SET returned_at = now() WHERE id = %s AND returned_at IS NULL RETURNING book_id",
            (loan_id,),
        ).fetchone()
        if not row:
            raise HTTPException(404, "loan not found or already returned")
        conn.execute("UPDATE books SET copies_available = copies_available + 1 WHERE id = %s", (row["book_id"],))
        return conn.execute(LOAN_SELECT + " WHERE l.id = %s", (loan_id,)).fetchone()


@app.get("/api/stress")
def stress(ms: int = Query(200, ge=1, le=1000)):
    """Burns CPU for `ms` milliseconds. Used to drive Auto Scaling in load tests."""
    end = time.perf_counter() + ms / 1000
    digest, rounds = b"seed", 0
    while time.perf_counter() < end:
        digest = hashlib.sha256(digest).digest()
        rounds += 1
    return {"burned_ms": ms, "hash_rounds": rounds}


# Static front end; must be mounted last so it doesn't shadow the API routes.
app.mount("/", StaticFiles(directory=FRONTEND_DIR, html=True), name="frontend")
