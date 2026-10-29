// Text that scrambles briefly, then resolves left to right.
export const GLYPHS = "#%&*+=-/\\|<>01$_";
export const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
export const glyph = () => GLYPHS[(Math.random() * GLYPHS.length) | 0];

/** Decode `el` to `text` (its current text by default). Only for elements without child markup. */
export function decode(el, ms = 520, text = el.textContent) {
  if (reduceMotion) {
    el.textContent = text;
    return;
  }
  const t0 = performance.now();
  const step = (now) => {
    const k = (now - t0) / ms;
    el.textContent = k >= 1 ? text : [...text].map((c, i) => (c === " " || i / text.length < k ? c : glyph())).join("");
    if (k < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

/** Decode each plain-text `[data-decode]` element once, when it scrolls into view. */
export function decodeOnView() {
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (!e.isIntersecting) continue;
      io.unobserve(e.target);
      if (!e.target.children.length) decode(e.target, 700);
    }
  }, { threshold: 0.6 });
  document.querySelectorAll("[data-decode]").forEach((el) => io.observe(el));
}
