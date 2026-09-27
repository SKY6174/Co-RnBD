import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { LegacyPage } from "@/components/legacy-page";
import { isPageId, PAGE_IDS, pageMetadata } from "@/lib/pages";

type PageProps = { params: Promise<{ slug: string }> };

export const dynamicParams = false;

export function generateStaticParams() {
  return PAGE_IDS.filter((pageId) => pageId !== "index").map((slug) => ({ slug }));
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { slug } = await params;
  if (!isPageId(slug) || slug === "index") notFound();
  return pageMetadata(slug);
}

export default async function ContentPage({ params }: PageProps) {
  const { slug } = await params;
  if (!isPageId(slug) || slug === "index") notFound();
  return <LegacyPage pageId={slug} />;
}
