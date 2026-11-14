import type { NextConfig } from "next";

const LEGACY_SLUGS = [
  "cfp",
  "program",
  "edition",
  "archive",
  "submission",
  "registration",
  "mypage",
  "document-admin",
  "document",
  "operations",
  "chair",
  "session-chair",
  "monitor",
  "privacy",
  "terms",
  "cmt-reference",
] as const;

// Supabase project origin for API, Auth, Storage and Realtime. Falls back to any
// Supabase project when the build has no SUPABASE_URL (local static checks).
function supabaseOrigins(): string[] {
  try {
    const url = new URL(process.env.SUPABASE_URL ?? "");
    if (url.protocol === "https:" || url.hostname === "127.0.0.1" || url.hostname === "localhost") {
      return [url.origin, url.origin.replace(/^http/, "ws")];
    }
  } catch {
    // fall through
  }
  return ["https://*.supabase.co", "wss://*.supabase.co"];
}

const isDev = process.env.NODE_ENV === "development";

// Next.js App Router emits inline bootstrap scripts on static pages, so scripts
// allow 'unsafe-inline' but only from this site and the pinned supabase-js CDN.
const contentSecurityPolicy = [
  "default-src 'self'",
  `script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net${isDev ? " 'unsafe-eval'" : ""}`,
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com",
  "img-src 'self' data: blob:",
  `connect-src 'self' https://cdn.jsdelivr.net ${supabaseOrigins().join(" ")}`,
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");

const securityHeaders = [
  { key: "Content-Security-Policy", value: contentSecurityPolicy },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()" },
];

const nextConfig: NextConfig = {
  async headers() {
    return [{ source: "/:path*", headers: securityHeaders }];
  },
  async rewrites() {
    return [
      { source: "/index.html", destination: "/" },
      ...LEGACY_SLUGS.map((slug) => ({
        source: `/${slug}.html`,
        destination: `/${slug}`,
      })),
    ];
  },
};

export default nextConfig;
