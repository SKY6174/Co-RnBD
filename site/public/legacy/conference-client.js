import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/+esm';

const CONFIG_CACHE_KEY = 'co_rnbd_runtime_config_v1';
const CONFIG_TTL_MS = 5 * 60 * 1000;

let cachedConfigPromise = null;
let cachedClient = null;
let cachedClientKey = '';

// Intl.DateTimeFormat 인스턴스를 싱글톤으로 재사용하여 반복 렌더링 속도 개선
const utcFullDateFormatter = new Intl.DateTimeFormat('ko-KR', {
  year: 'numeric',
  month: 'long',
  day: 'numeric',
  timeZone: 'UTC',
});

const kstShortDateFormatter = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  month: 'long',
  day: 'numeric',
  weekday: 'short',
});

const kstTimeFormatter = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

export const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);

export function requireData(result) {
  if (result.error) throw result.error;
  return result.data;
}

function readCachedConfig() {
  try {
    const raw = window.sessionStorage.getItem(CONFIG_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed?.data?.url || !parsed?.data?.publishableKey) return null;
    const age = Date.now() - parsed.cachedAt;
    if (!Number.isFinite(parsed.cachedAt) || age < 0 || age >= CONFIG_TTL_MS) return null;
    return parsed.data;
  } catch {
    return null;
  }
}

function writeCachedConfig(data) {
  try {
    if (data?.url && data?.publishableKey) {
      window.sessionStorage.setItem(
        CONFIG_CACHE_KEY,
        JSON.stringify({ cachedAt: Date.now(), data }),
      );
    }
  } catch {
    // sessionStorage 비활성 환경에서는 무시
  }
}

export async function conferenceConfig() {
  const fromStorage = readCachedConfig();
  if (fromStorage) return fromStorage;
  if (!cachedConfigPromise) {
    cachedConfigPromise = fetch('/api/config')
      .then(async (response) => {
        if (!response.ok) throw new Error('사이트 데이터 연결을 확인할 수 없습니다.');
        const data = await response.json();
        writeCachedConfig(data);
        return data;
      })
      .finally(() => {
        cachedConfigPromise = null;
      });
  }
  return cachedConfigPromise;
}

export async function conferenceClient(config) {
  const resolved = config ?? await conferenceConfig();
  const { url, publishableKey } = resolved;
  if (!url || !publishableKey) throw new Error('사이트 데이터 설정이 완료되지 않았습니다.');
  const key = `${url}::${publishableKey}`;
  if (!cachedClient || cachedClientKey !== key) {
    cachedClient = createClient(url, publishableKey);
    cachedClientKey = key;
  }
  return cachedClient;
}

export async function currentEdition(client) {
  return requireData(await client.from('conference_editions')
    .select('year,title,start_date,end_date,venue,summary,status')
    .eq('status', 'current').single());
}

export function editionDateRange(edition) {
  if (!edition.start_date || !edition.end_date) return '일정 확정 전';
  const date = (value) => utcFullDateFormatter.format(new Date(`${value}T00:00:00Z`));
  return edition.start_date === edition.end_date
    ? date(edition.start_date) : `${date(edition.start_date)}–${date(edition.end_date)}`;
}

export function kstDate(value) {
  return kstShortDateFormatter.format(new Date(value));
}

export function kstTime(value) {
  return kstTimeFormatter.format(new Date(value));
}


export function renderConferenceContext(edition) {
  const panel = document.querySelector('[data-conference-context]');
  if (!panel) return;
  panel.innerHTML = `<div class="conference-context-heading"><span>${edition.status === 'archived' ? '지난 학회' : '참여 학회'}</span><strong>${escapeHtml(edition.title)}</strong></div>
    <dl><div><dt>개최 기간</dt><dd>${escapeHtml(editionDateRange(edition))}</dd></div>
    <div><dt>개최 장소</dt><dd>${escapeHtml(edition.venue || '장소 확정 전')}</dd></div></dl>`;
  panel.hidden = false;
  document.querySelectorAll('[data-conference-footer]').forEach((element) => {
    element.textContent = edition.title;
  });
}
