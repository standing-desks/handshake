// Read the published release on each visit, independently of website deployments.
(async () => {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10000);
  try {
    const response = await fetch("https://api.github.com/repos/standing-desks/handshake/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
      cache: "no-store",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error("Release lookup failed");
    const release = await response.json();
    if (typeof release.tag_name !== "string" || !release.tag_name.trim()) return;
    for (const element of document.querySelectorAll("[data-release-version]")) {
      element.textContent = release.tag_name;
    }
  } catch {
    // Keep the version-neutral HTML when GitHub is unavailable or rate limited.
  } finally {
    clearTimeout(timeout);
  }
})();
