import { resolve } from "node:path";
import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react";
import tsconfigPaths from "vite-tsconfig-paths";
import basicSsl from "@vitejs/plugin-basic-ssl";

// The Doctor phone pages are served from phone.html (see that file). In dev, send
// those addresses to it; nginx does the same in production.
const PHONE_PAGE = /^\/phone\/?$|^\/phone\/pair\/?$|^\/[^/.]+\/phone\/?$/;
const phonePages = () => ({
  name: "phone-pages",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      const [path, query] = (req.url || "").split("?");
      if (PHONE_PAGE.test(path)) req.url = `/phone.html${query ? `?${query}` : ""}`;
      next();
    });
  },
});

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  // Local-only: serve https with a self-signed certificate so phones allow the
  // microphone/camera, and forward /sb to the local Supabase stack so a phone
  // never needs to reach 127.0.0.1. Both are opt-in via .env.local.
  const devHttps = env.VITE_DEV_HTTPS === "true";
  const supabaseProxyTarget = env.VITE_DEV_SUPABASE_PROXY_TARGET;

  return {
    build: {
      outDir: "build",
      chunkSizeWarningLimit: 2000,
      rollupOptions: {
        input: { main: resolve("index.html"), phone: resolve("phone.html") },
      },
    },
    plugins: [tsconfigPaths(), react(), phonePages(), ...(devHttps ? [basicSsl()] : [])],
    server: {
      port: 4028,
      host: "0.0.0.0",
      strictPort: true,
      allowedHosts: ['.trycloudflare.com', 'dev-app.zennly.io', 'app.zennly.io', 'dev-zenly.zunkireelabs.com', 'zenly.zunkireelabs.com'],
      ...(supabaseProxyTarget
        ? {
            proxy: {
              "/sb": {
                target: supabaseProxyTarget,
                changeOrigin: true,
                ws: true,
                rewrite: (path) => path.replace(/^\/sb/, ""),
              },
            },
          }
        : {}),
    },
  };
});
