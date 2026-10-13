const $ = (id) => document.getElementById(id);

function cell(text) {
  const td = document.createElement("td");
  td.textContent = text;
  return td;
}

function say(text, ok) {
  $("message").className = ok ? "ok" : "error";
  $("message").textContent = text;
}

async function api(path, options) {
  const res = await fetch(path, options);
  if (!res.ok) {
    let detail = res.statusText;
    try { detail = (await res.json()).detail || detail; } catch { /* not JSON */ }
    throw new Error(typeof detail === "string" ? detail : "invalid input");
  }
  return res.json();
}

const post = (path, body) => api(path, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});

function fill(table, rows) {
  const tbody = $(table).tBodies[0];
  tbody.replaceChildren();
  for (const cells of rows) {
    const tr = document.createElement("tr");
    tr.append(...cells);
    tbody.append(tr);
  }
}

function setOptions(select, items, label) {
  const el = $(select);
  el.replaceChildren();
  for (const item of items) {
    const o = document.createElement("option");
    o.value = item.id;
    o.textContent = label(item);
    el.append(o);
  }
}

async function loadInfo() {
  try {
    const i = await api("/api/info");
    $("served-by").textContent = `Served by: ${i.instance_id} (${i.availability_zone})`;
  } catch {
    $("served-by").textContent = "Served by: unknown";
  }
}

async function loadBooks() {
  const books = await api("/api/books");
  fill("books", books.map((b) => [cell(b.title), cell(b.author), cell(b.isbn || "-"), cell(`${b.copies_available} / ${b.copies_total}`)]));
  setOptions("loan-book", books.filter((b) => b.copies_available > 0), (b) => `${b.title} (${b.copies_available} left)`);
}

async function loadMembers() {
  const members = await api("/api/members");
  fill("members", members.map((m) => [cell(m.id), cell(m.name), cell(m.email)]));
  setOptions("loan-member", members, (m) => `${m.name} (${m.email})`);
}

async function loadLoans() {
  const loans = await api("/api/loans");
  fill("loans", loans.map((l) => {
    const status = document.createElement("td");
    if (l.returned_at) {
      status.textContent = "Returned";
    } else {
      const btn = document.createElement("button");
      btn.textContent = "Return";
      btn.onclick = async () => {
        try { await api(`/api/loans/${l.id}/return`, { method: "POST" }); say("Book returned.", true); refresh(); }
        catch (e) { say(`Failed: ${e.message}`, false); }
      };
      status.append(btn);
    }
    return [cell(l.id), cell(l.book_title), cell(l.member_name), cell(new Date(l.due_at).toLocaleDateString()), status];
  }));
}

const refresh = () => Promise.all([loadBooks(), loadMembers(), loadLoans()]).catch((e) => say(e.message, false));

function onSubmit(formId, handler) {
  $(formId).addEventListener("submit", async (e) => {
    e.preventDefault();
    try { await handler(); refresh(); } catch (err) { say(`Failed: ${err.message}`, false); }
  });
}

onSubmit("book-form", async () => {
  const b = await post("/api/books", {
    title: $("book-title").value, author: $("book-author").value,
    isbn: $("book-isbn").value || null, copies: Number($("book-copies").value),
  });
  say(`Added "${b.title}".`, true);
  $("book-form").reset();
});

onSubmit("member-form", async () => {
  const m = await post("/api/members", { name: $("member-name").value, email: $("member-email").value });
  say(`Added member ${m.name}.`, true);
  $("member-form").reset();
});

onSubmit("loan-form", async () => {
  const l = await post("/api/loans", { member_id: Number($("loan-member").value), book_id: Number($("loan-book").value) });
  say(`Issued "${l.book_title}" to ${l.member_name}.`, true);
});

loadInfo();
refresh();
