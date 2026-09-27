import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.57.0/+esm';

export const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);

export function requireData(result) {
  if (result.error) throw result.error;
  return result.data;
}

export async function conferenceClient() {
  const response = await fetch('/api/config', { cache: 'no-store' });
  if (!response.ok) throw new Error('사이트 데이터 연결을 확인할 수 없습니다.');
  const { url, publishableKey } = await response.json();
  if (!url || !publishableKey) throw new Error('사이트 데이터 설정이 완료되지 않았습니다.');
  return createClient(url, publishableKey);
}

export async function currentEdition(client) {
  return requireData(await client.from('conference_editions')
    .select('year,title,start_date,end_date,venue,summary,status')
    .eq('status', 'current').single());
}

export function editionDateRange(edition) {
  if (!edition.start_date || !edition.end_date) return '일정 확정 전';
  const date = (value) => new Intl.DateTimeFormat('ko-KR', {
    year: 'numeric', month: 'long', day: 'numeric', timeZone: 'UTC',
  }).format(new Date(`${value}T00:00:00Z`));
  return edition.start_date === edition.end_date
    ? date(edition.start_date) : `${date(edition.start_date)}–${date(edition.end_date)}`;
}

export function kstDate(value) {
  return new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', month: 'long', day: 'numeric', weekday: 'short' }).format(new Date(value));
}

export function kstTime(value) {
  return new Intl.DateTimeFormat('ko-KR', { timeZone: 'Asia/Seoul', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(value));
}
