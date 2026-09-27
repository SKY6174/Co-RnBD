const menuToggle = document.querySelector(".menu-toggle");
const primaryNav = document.querySelector(".primary-nav");
const dayTabs = Array.from(document.querySelectorAll(".day-tab"));

// The editorial 2026 home remains a record of the inaugural edition.
// Later current editions use the database-driven landing page.
fetch('/api/config').then((response) => response.ok ? response.json() : null)
  .then(async (config) => {
    if (!config?.url || !config?.publishableKey) return;
    const response = await fetch(`${config.url}/rest/v1/conference_editions?status=eq.current&select=year`, {
      headers: { apikey: config.publishableKey, Authorization: `Bearer ${config.publishableKey}` },
      cache: 'no-store',
    });
    if (!response.ok) return;
    const editions = await response.json();
    if (editions[0]?.year > 2026) location.replace('./edition.html');
  }).catch(() => { /* Static 2026 information remains available during outages. */ });

function setMenuOpen(isOpen) {
  menuToggle.setAttribute("aria-expanded", String(isOpen));
  menuToggle.setAttribute("aria-label", isOpen ? "메뉴 닫기" : "메뉴 열기");
  primaryNav.classList.toggle("is-open", isOpen);
}

menuToggle.addEventListener("click", () => {
  setMenuOpen(menuToggle.getAttribute("aria-expanded") !== "true");
});

primaryNav.addEventListener("click", (event) => {
  if (event.target.closest("a")) setMenuOpen(false);
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && menuToggle.getAttribute("aria-expanded") === "true") {
    setMenuOpen(false);
    menuToggle.focus();
  }
});

function activateDayTab(activeTab, focusTab = false) {
  dayTabs.forEach((tab) => {
    const isActive = tab === activeTab;
    const panel = document.getElementById(tab.getAttribute("aria-controls"));
    tab.classList.toggle("active", isActive);
    tab.setAttribute("aria-selected", String(isActive));
    tab.tabIndex = isActive ? 0 : -1;
    panel.hidden = !isActive;
  });

  if (focusTab) activeTab.focus();
}

dayTabs.forEach((tab, index) => {
  tab.addEventListener("click", () => activateDayTab(tab));
  tab.addEventListener("keydown", (event) => {
    let nextIndex = index;
    if (event.key === "ArrowRight") nextIndex = (index + 1) % dayTabs.length;
    else if (event.key === "ArrowLeft") nextIndex = (index - 1 + dayTabs.length) % dayTabs.length;
    else if (event.key === "Home") nextIndex = 0;
    else if (event.key === "End") nextIndex = dayTabs.length - 1;
    else return;

    event.preventDefault();
    activateDayTab(dayTabs[nextIndex], true);
  });
});
