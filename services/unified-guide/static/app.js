// Fetches /api/grid every 60s, renders one lane per channel, click → launch.
(() => {
  const $ = (s, p = document) => p.querySelector(s);
  const grid = $("#grid");
  const genEl = $("#generated");
  const cntEl = $("#counts");
  const search = $("#search");
  const refreshBtn = $("#refresh");
  const sourceCheckboxes = () => Array.from(document.querySelectorAll('.filters input[type=checkbox]'));

  let state = { records: [], counts: {}, generated_at: null };

  function fmtTime(iso) {
    if (!iso) return "";
    try {
      const d = new Date(iso);
      return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    } catch { return ""; }
  }
  function fmtAge(iso) {
    if (!iso) return "—";
    const d = new Date(iso); const s = (Date.now() - d.getTime()) / 1000;
    if (s < 60) return "just now";
    if (s < 3600) return Math.floor(s/60) + " min ago";
    return Math.floor(s/3600) + " h ago";
  }
  function isAiringNow(r) {
    if (!r.start || !r.stop) return false;
    const now = Date.now();
    return new Date(r.start).getTime() <= now && now < new Date(r.stop).getTime();
  }
  function activeSources() {
    return sourceCheckboxes().filter(c => c.checked).map(c => c.dataset.source);
  }

  function lanesFromRecords(records) {
    // Group by (source, channel_name); pick currently-airing first within each lane.
    const byLane = new Map();
    for (const r of records) {
      const key = `${r.source}::${r.channel_name}`;
      if (!byLane.has(key)) byLane.set(key, { source: r.source, channel: r.channel_name, items: [] });
      byLane.get(key).items.push(r);
    }
    // Sort each lane: current first, then by start ascending
    for (const lane of byLane.values()) {
      lane.items.sort((a, b) => {
        const an = isAiringNow(a) ? 0 : 1;
        const bn = isAiringNow(b) ? 0 : 1;
        if (an !== bn) return an - bn;
        const ad = a.start ? new Date(a.start).getTime() : 0;
        const bd = b.start ? new Date(b.start).getTime() : 0;
        return ad - bd;
      });
    }
    // Order lanes: linear (sorted by channel) then virtual (svod, local) at top of their type
    const order = { ota: 0, iptv: 1, yttv: 2, svod: 3, local: 4 };
    return Array.from(byLane.values()).sort((a, b) => {
      const da = order[a.source] ?? 9, db = order[b.source] ?? 9;
      if (da !== db) return da - db;
      return a.channel.localeCompare(b.channel);
    });
  }

  function render() {
    if (!state.records.length) {
      grid.innerHTML = '<p class="empty">No records yet — refresh in a moment.</p>';
      return;
    }
    const sources = new Set(activeSources());
    const q = (search.value || "").trim().toLowerCase();
    let recs = state.records.filter(r => sources.has(r.source));
    if (q) recs = recs.filter(r =>
      (r.title || "").toLowerCase().includes(q) ||
      (r.channel_name || "").toLowerCase().includes(q));

    const lanes = lanesFromRecords(recs);
    const frag = document.createDocumentFragment();
    for (const lane of lanes) {
      const laneEl = document.createElement("section");
      laneEl.className = "lane";
      const head = document.createElement("div");
      head.className = "lane-head";
      head.dataset.source = lane.source;
      head.innerHTML = `<span class="source">${lane.source}</span><span class="name"></span>`;
      head.querySelector(".name").textContent = lane.channel;
      laneEl.appendChild(head);

      const cells = document.createElement("div");
      cells.className = "lane-cells";
      const max = lane.source === "svod" || lane.source === "local" ? 30 : 12;
      for (const r of lane.items.slice(0, max)) {
        const cell = document.createElement("button");
        cell.type = "button";
        cell.className = "cell" + (isAiringNow(r) ? " now" : "");
        cell.dataset.source = r.source;
        cell.dataset.channel = r.channel_name;
        cell.dataset.url = r.launch_url || "";
        cell.dataset.requestUrl = r.request_url || "";
        const time = (r.start && r.stop)
          ? `${fmtTime(r.start)}–${fmtTime(r.stop)}`
          : (r.source === "svod" ? "On demand" : "");
        cell.innerHTML = `
          <span class="req" title="Request via Riven (Real-Debrid → JD2 → Jellyfin)">+</span>
          <div class="title"></div>
          <div class="time"></div>
          <div class="desc"></div>
        `;
        cell.querySelector(".title").textContent = r.title || "(untitled)";
        cell.querySelector(".time").textContent  = time;
        cell.querySelector(".desc").textContent  = r.desc || "";
        if (!r.request_url) cell.querySelector(".req").hidden = true;
        cells.appendChild(cell);
      }
      laneEl.appendChild(cells);
      frag.appendChild(laneEl);
    }
    grid.replaceChildren(frag);
  }

  // Single global click handler. Cell click → launch the right player. The
  // tiny + badge → Riven request page (closes the loop: see-it-on-SVOD →
  // ingest via RD → JD2 → Jellyfin). Right-click on the cell also opens Riven.
  document.addEventListener("click", (ev) => {
    const reqBtn = ev.target.closest(".req");
    if (reqBtn) {
      const cell = reqBtn.closest(".cell");
      const reqUrl = cell && cell.dataset.requestUrl;
      if (reqUrl) {
        ev.stopPropagation();
        window.open(reqUrl, "_blank", "noopener");
      }
      return;
    }
    const cell = ev.target.closest(".cell");
    if (!cell) return;
    const url = cell.dataset.url;
    if (!url) return;
    // Open in same tab so app handlers (Netflix://, YouTube TV, Jellyfin) can claim it.
    // Hold ctrl/cmd or middle-click to keep new-tab behavior.
    if (ev.ctrlKey || ev.metaKey || ev.button === 1) {
      window.open(url, "_blank", "noopener");
    } else {
      window.location.href = url;
    }
  });
  document.addEventListener("contextmenu", (ev) => {
    const cell = ev.target.closest(".cell");
    if (!cell) return;
    const reqUrl = cell.dataset.requestUrl;
    if (!reqUrl) return;
    ev.preventDefault();
    window.open(reqUrl, "_blank", "noopener");
  });

  async function fetchGrid() {
    try {
      const r = await fetch("/api/grid", { cache: "no-store" });
      state = await r.json();
      genEl.textContent = `generated: ${fmtAge(state.generated_at)}`;
      const c = state.counts || {};
      cntEl.textContent =
        `OTA ${c.ota||0} • IPTV ${c.iptv||0} • YT TV ${c.yttv||0} • SVOD ${c.svod||0} • Library ${c.local||0}`;
      render();
    } catch (e) {
      grid.innerHTML = `<p class="empty">Failed to load: ${e}</p>`;
    }
  }

  refreshBtn.addEventListener("click", async () => {
    refreshBtn.disabled = true;
    try {
      await fetch("/api/refresh", { method: "POST" });
      // Server triggers async refresh; give it a moment.
      setTimeout(fetchGrid, 4000);
    } finally { refreshBtn.disabled = false; }
  });

  search.addEventListener("input", render);
  sourceCheckboxes().forEach(cb => cb.addEventListener("change", render));

  fetchGrid();
  setInterval(fetchGrid, 60_000);
})();
