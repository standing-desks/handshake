import { resolve } from "node:path";
import { defineConfig } from "vite";

const page = (path) => resolve(import.meta.dirname, path);

export default defineConfig({
  // Relative URLs let the same build work under the /handshake/ Pages path.
  base: "./",
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
