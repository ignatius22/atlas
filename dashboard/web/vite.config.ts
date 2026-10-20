import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The production build is served by dashboard/server.py from dashboard/dist,
// so the VPS never needs Node.js. `npm run dev` proxies the API to a local server.
export default defineConfig({
  plugins: [react()],
  base: "./",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    sourcemap: false,
  },
  server: {
    proxy: {
      "/api": process.env.ATLAS_API_URL ?? "http://127.0.0.1:8888",
    },
  },
  test: {
    environment: "node",
  },
});
