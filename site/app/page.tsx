import type { Metadata } from "next";
import { LegacyPage } from "@/components/legacy-page";
import { pageMetadata } from "@/lib/pages";

export const metadata: Metadata = pageMetadata("index");

export default function HomePage() {
  return <LegacyPage pageId="index" />;
}
