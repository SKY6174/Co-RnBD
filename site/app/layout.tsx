import type { Metadata, Viewport } from "next";
import type { ReactNode } from "react";
import "../styles.css";
import "../submission.css";
import "../operations.css";
import "../legal.css";

export const metadata: Metadata = {
  title: "T-VET Co-R&BD Conference",
  icons: { icon: "/favicon.png" },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#08201e",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="ko">
      <body>{children}</body>
    </html>
  );
}
