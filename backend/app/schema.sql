CREATE TABLE IF NOT EXISTS books (
    id               SERIAL PRIMARY KEY,
    title            TEXT NOT NULL,
    author           TEXT NOT NULL,
    isbn             TEXT UNIQUE,
    copies_total     INTEGER NOT NULL CHECK (copies_total >= 0),
    copies_available INTEGER NOT NULL CHECK (copies_available >= 0 AND copies_available <= copies_total)
);

CREATE TABLE IF NOT EXISTS members (
    id    SERIAL PRIMARY KEY,
    name  TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS loans (
    id          SERIAL PRIMARY KEY,
    book_id     INTEGER NOT NULL REFERENCES books(id),
    member_id   INTEGER NOT NULL REFERENCES members(id),
    issued_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    due_at      TIMESTAMPTZ NOT NULL DEFAULT now() + interval '14 days',
    returned_at TIMESTAMPTZ
);

INSERT INTO books (title, author, isbn, copies_total, copies_available)
SELECT * FROM (VALUES
    ('Introduction to Algorithms', 'Thomas H. Cormen', '9780262046305', 3, 3),
    ('Computer Networks', 'Andrew S. Tanenbaum', '9780132126953', 2, 2),
    ('Operating System Concepts', 'Abraham Silberschatz', '9781119800361', 3, 3),
    ('Database System Concepts', 'Abraham Silberschatz', '9780078022159', 2, 2),
    ('Designing Data-Intensive Applications', 'Martin Kleppmann', '9781449373320', 2, 2),
    ('Cloud Computing: Concepts, Technology & Architecture', 'Thomas Erl', '9780133387520', 2, 2)
) AS v(title, author, isbn, copies_total, copies_available)
WHERE NOT EXISTS (SELECT 1 FROM books);

INSERT INTO members (name, email)
SELECT * FROM (VALUES
    ('Asha Verma', 'asha.verma@example.com'),
    ('Rohan Mehta', 'rohan.mehta@example.com')
) AS v(name, email)
WHERE NOT EXISTS (SELECT 1 FROM members);
