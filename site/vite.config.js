import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";

const page = (path) => resolve(import.meta.dirname, path);

// Pages show the workspace version, so a release bump updates the site.
const cargo = readFileSync(page("../Cargo.toml"), "utf8");
const version = cargo.match(/^\[workspace\.package\][^[]*?^version\s*=\s*"([^"]+)"/ms)?.[1];
if (!version) throw new Error("Couldn't read the workspace version from Cargo.toml");

export default defineConfig({
  // Relative URLs let the same build work under the /handshake/ Pages path.
  base: "./",
  plugins: [{ name: "handshake-version", transformIndexHtml: (html) => html.replaceAll("%HANDSHAKE_VERSION%", version) }],
  build: {
    rollupOptions: {
      input: {
        main: page("index.html"),
        documentation: page("documentation/index.html"),
        guide: page("documentation/guide/index.html"),
        development: page("documentation/development/index.html"),
      },
    },
  },
});
