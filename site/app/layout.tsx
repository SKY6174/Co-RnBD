import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import "../styles.css";
import "../submission.css";
import "../operations.css";
import "../member-documents.css";
import "../chair.css";
import "../legal.css";

export const metadata: Metadata = {
  title: "TVET Co-R&BD Conference",
  applicationName: "Co-R&BD",
  icons: {
    icon: "/favicon.png",
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  appleWebApp: {
    capable: true,
    title: "Co-R&BD",
    statusBarStyle: "default",
  },
};

const registerServiceWorker = `if ("serviceWorker" in navigator) {
  window.addEventListener("load", function () {
    navigator.serviceWorker.register("/sw.js").catch(function () {});
  });
}`;

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#08201e",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="ko">
      <head>
        <link rel="preconnect" href="https://cdn.jsdelivr.net" crossOrigin="anonymous" />
        <link rel="dns-prefetch" href="https://cdn.jsdelivr.net" />
      </head>
      <body>
        {children}
        <script dangerouslySetInnerHTML={{ __html: registerServiceWorker }} />
      </body>
    </html>
  );
}
