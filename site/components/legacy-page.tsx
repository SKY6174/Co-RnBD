import Script from "next/script";
import { EditorialInteractions } from "@/components/editorial-interactions";
import { pageBody, pageScript, type PageId } from "@/lib/pages";

type LegacyPageProps = { pageId: PageId };

export function LegacyPage({ pageId }: LegacyPageProps) {
  const script = pageScript(pageId);

  return (
    <>
      <div dangerouslySetInnerHTML={{ __html: pageBody(pageId) }} />
      {pageId === "index" || pageId === "cfp" ? <EditorialInteractions /> : null}
      {script ? <Script src={`/legacy/${script}`} type="module" strategy="afterInteractive" /> : null}
    </>
  );
}
