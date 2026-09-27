"use client";

import { useEffect } from "react";

type PublicConfig = { url?: string; publishableKey?: string };
type CurrentEdition = { year?: number };

export function EditorialInteractions() {
  useEffect(() => {
    const menuToggle = document.querySelector<HTMLButtonElement>(".menu-toggle");
    const primaryNav = document.querySelector<HTMLElement>(".primary-nav");
    const dayTabs = Array.from(document.querySelectorAll<HTMLButtonElement>(".day-tab"));
    const controller = new AbortController();

    function setMenuOpen(isOpen: boolean) {
      if (!menuToggle || !primaryNav) return;
      menuToggle.setAttribute("aria-expanded", String(isOpen));
      menuToggle.setAttribute("aria-label", isOpen ? "메뉴 닫기" : "메뉴 열기");
      primaryNav.classList.toggle("is-open", isOpen);
    }

    function onMenuClick() {
      setMenuOpen(menuToggle?.getAttribute("aria-expanded") !== "true");
    }

    function onNavigationClick(event: MouseEvent) {
      if (event.target instanceof Element && event.target.closest("a")) setMenuOpen(false);
    }

    function onDocumentKeydown(event: KeyboardEvent) {
      if (event.key === "Escape" && menuToggle?.getAttribute("aria-expanded") === "true") {
        setMenuOpen(false);
        menuToggle.focus();
      }
    }

    function activateDayTab(activeTab: HTMLButtonElement, focusTab = false) {
      dayTabs.forEach((tab) => {
        const isActive = tab === activeTab;
        const panelId = tab.getAttribute("aria-controls");
        const panel = panelId ? document.getElementById(panelId) : null;
        tab.classList.toggle("active", isActive);
        tab.setAttribute("aria-selected", String(isActive));
        tab.tabIndex = isActive ? 0 : -1;
        if (panel) panel.hidden = !isActive;
      });
      if (focusTab) activeTab.focus();
    }

    const tabCleanups = dayTabs.map((tab, index) => {
      const onClick = () => activateDayTab(tab);
      const onKeydown = (event: KeyboardEvent) => {
        let nextIndex = index;
        if (event.key === "ArrowRight") nextIndex = (index + 1) % dayTabs.length;
        else if (event.key === "ArrowLeft") nextIndex = (index - 1 + dayTabs.length) % dayTabs.length;
        else if (event.key === "Home") nextIndex = 0;
        else if (event.key === "End") nextIndex = dayTabs.length - 1;
        else return;
        event.preventDefault();
        activateDayTab(dayTabs[nextIndex], true);
      };
      tab.addEventListener("click", onClick);
      tab.addEventListener("keydown", onKeydown);
      return () => {
        tab.removeEventListener("click", onClick);
        tab.removeEventListener("keydown", onKeydown);
      };
    });

    menuToggle?.addEventListener("click", onMenuClick);
    primaryNav?.addEventListener("click", onNavigationClick);
    document.addEventListener("keydown", onDocumentKeydown);

    async function redirectToCurrentEdition() {
      try {
        const configResponse = await fetch("/api/config", { signal: controller.signal });
        if (!configResponse.ok) return;
        const config: PublicConfig = await configResponse.json();
        if (!config.url || !config.publishableKey) return;
        const editionResponse = await fetch(
          config.url + "/rest/v1/conference_editions?status=eq.current&select=year",
          {
            headers: {
              apikey: config.publishableKey,
              Authorization: "Bearer " + config.publishableKey,
            },
            cache: "no-store",
            signal: controller.signal,
          },
        );
        if (!editionResponse.ok) return;
        const editions: CurrentEdition[] = await editionResponse.json();
        if (editions[0]?.year && editions[0].year > 2026) {
          window.location.replace("/edition.html");
        }
      } catch {
        // The editorial 2026 pages remain available when the data service is offline.
      }
    }

    void redirectToCurrentEdition();

    return () => {
      controller.abort();
      menuToggle?.removeEventListener("click", onMenuClick);
      primaryNav?.removeEventListener("click", onNavigationClick);
      document.removeEventListener("keydown", onDocumentKeydown);
      tabCleanups.forEach((cleanup) => cleanup());
    };
  }, []);

  return null;
}
