// Home page: the slogan the agents repair, the workflow-type screenshots, and the harness cycler.
import "./download.js";
import "./release.js";
import { decode, decodeOnView, glyph, reduceMotion } from "./decode.js";

decodeOnView();

/* Hero: the visitor breaks letters; role cursors fix them. */
const hero = document.getElementById("hero");
const letters = [];
for (const line of hero.querySelectorAll(".slogan .line")) {
  const text = line.textContent;
  line.textContent = "";
  for (const ch of text) {
    const el = document.createElement("span");
    el.textContent = ch;
    line.append(el);
    letters.push({ el, ch, broken: false, claimed: false });
  }
}
const strong = hero.querySelector(".l3");

// Implementer, coordinator, reviewer: the order they rest in along the hero.
const ROLES = [
  ["implementer", "var(--codex)"],
  ["coordinator", "var(--coordinator)"],
  ["reviewer", "var(--claude)"],
];

if (!reduceMotion) {
  const agents = ROLES.map(([name, color], i) => {
    const el = document.createElement("div");
    el.className = "agent";
    el.setAttribute("aria-hidden", "true");
    el.innerHTML = `<svg width="22" height="24" viewBox="0 0 22 24"><path d="M2 1v19l5-5 3.4 7.2 3.1-1.4L10.2 14H17z" style="fill:${color}"/></svg><i style="background:${color}">${name}</i>`;
    hero.append(el);
    const x = 120 + i * 200, y = hero.clientHeight + 40;
    return { el, x, y, previousX: x, previousY: y, target: null, home: { x: 0, y: 0 } };
  });

  const placeHomes = () => {
    const w = hero.clientWidth, h = hero.clientHeight;
    agents.forEach((a, i) => (a.home = { x: w * (0.3 + i * 0.1), y: h - 104 - (i % 2) * 8 }));
  };
  placeHomes();
  addEventListener("resize", placeHomes);

  const center = (el) => {
    const r = el.getBoundingClientRect(), h = hero.getBoundingClientRect();
    return { x: r.left - h.left + r.width * 0.45, y: r.top - h.top + r.height * 0.55 };
  };
  const breakLetter = (l) => {
    if (l.broken) return;
    l.broken = true;
    l.el.classList.add("hot");
  };
  const fix = (l) => {
    l.broken = l.claimed = false;
    l.el.textContent = l.ch;
    l.el.classList.remove("hot");
  };
  const nearest = (a) => {
    let best = null, bestDistance = Infinity;
    for (const l of letters) {
      if (!l.broken || l.claimed) continue;
      const c = center(l.el), d = Math.hypot(c.x - a.x, c.y - a.y);
      if (d < bestDistance) [best, bestDistance] = [l, d];
    }
    if (best) best.claimed = true;
    return best;
  };

  hero.addEventListener("pointermove", (e) => {
    const h = hero.getBoundingClientRect(), x = e.clientX - h.left, y = e.clientY - h.top;
    for (const l of letters) {
      const c = center(l.el);
      if (Math.hypot(c.x - x, c.y - y) < 70) breakLetter(l);
    }
  });
  hero.addEventListener("click", () => letters.forEach(breakLetter));
  setInterval(() => letters.forEach((l) => l.broken && (l.el.textContent = glyph())), 60);

  // STRONG thickens as the headline resolves.
  const STEP_MS = 1000 / 60;
  const MAX_ELAPSED_MS = 100;
  let weight = 120, previousWeight = weight;
  let lastTime = null, pending = 0, time = 0;
  const simulate = (now) => {
    previousWeight = weight;
    for (const a of agents) {
      a.previousX = a.x;
      a.previousY = a.y;
      a.target ??= nearest(a);
      const t = a.target
        ? center(a.target.el)
        : { x: a.home.x + Math.sin(now / 900 + a.home.x) * 6, y: a.home.y + Math.cos(now / 1100 + a.home.x) * 4 };
      const k = a.target ? 0.16 : 0.05;
      a.x += (t.x - a.x) * k;
      a.y += (t.y - a.y) * k;
      if (a.target && Math.hypot(t.x - a.x, t.y - a.y) < 8) {
        fix(a.target);
        a.target = null;
      }
    }
    const fixed = letters.filter((l) => !l.broken).length / letters.length;
    weight += (120 + 680 * fixed ** 3 - weight) * 0.08;
  };
  document.addEventListener("visibilitychange", () => { lastTime = null; });
  const tick = (now) => {
    if (!document.hidden) {
      if (lastTime === null) lastTime = now;
      pending += Math.max(0, Math.min(now - lastTime, MAX_ELAPSED_MS));
      lastTime = now;
      // Preserve the 60 Hz tuning; tolerate rounding at exact tick boundaries.
      while (pending + 1e-7 >= STEP_MS) {
        pending = Math.max(0, pending - STEP_MS);
        time += STEP_MS;
        simulate(time);
      }
      // Draw between fixed ticks so high-refresh displays still get smooth motion.
      const blend = pending / STEP_MS;
      for (const a of agents) {
        const x = a.previousX + (a.x - a.previousX) * blend;
        const y = a.previousY + (a.y - a.previousY) * blend;
        a.el.style.transform = `translate(${x}px, ${y}px)`;
      }
      strong.style.fontWeight = Math.round(previousWeight + (weight - previousWeight) * blend);
    } else {
      lastTime = null;
    }
    requestAnimationFrame(tick);
  };
  requestAnimationFrame(tick);
  setTimeout(() => letters.forEach(breakLetter), 350);
}

/* Workflow types: each row shows its screenshot. */
const rows = [...document.querySelectorAll(".workflows .row")];
const shotImg = document.getElementById("shot-img");
const shotMissing = document.getElementById("shot-missing");

shotImg.addEventListener("load", () => {
  shotImg.hidden = false;
  shotMissing.hidden = true;
});
shotImg.addEventListener("error", () => {
  shotImg.hidden = true;
  shotMissing.hidden = false;
});

function select(row) {
  if (row.classList.contains("on")) return;
  for (const r of rows) {
    r.classList.toggle("on", r === row);
    r.setAttribute("aria-pressed", String(r === row));
  }
  shotImg.alt = row.dataset.alt;
  shotImg.src = row.dataset.shot;
}
for (const row of rows) {
  row.addEventListener("click", () => select(row));
  row.addEventListener("pointerenter", (e) => e.pointerType === "mouse" && select(row));
}

/* Harnesses: each role cycles through the tools that can fill it. */
const HARNESSES = ["Codex", "Claude Code", "pi", "Antigravity", "OMP", "OpenCode", "Kiro CLI"];
const cyclers = [...document.querySelectorAll("[data-cycle]")];
let turn = 0;
if (!reduceMotion) {
  setInterval(() => {
    turn++;
    for (const el of cyclers) decode(el, 450, HARNESSES[(Number(el.dataset.cycle) + turn) % HARNESSES.length]);
  }, 2200);
}
