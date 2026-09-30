import type { NextConfig } from "next";

const LEGACY_SLUGS = [
  "cfp",
  "program",
  "edition",
  "archive",
  "submission",
  "registration",
  "operations",
  "session-chair",
  "chair-application",
  "monitor",
  "privacy",
  "terms",
  "cmt-reference",
] as const;

const nextConfig: NextConfig = {
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
