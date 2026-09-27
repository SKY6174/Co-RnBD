import { conferenceClient, editionDateRange, escapeHtml, requireData } from './conference-client.js';

async function start() {
  const message = document.querySelector('#archive-message');
  const list = document.querySelector('#archive-list');
  try {
    const client = await conferenceClient();
    const rows = requireData(await client.from('conference_editions')
      .select('year,title,start_date,end_date,venue,summary')
      .eq('status', 'archived').eq('archive_published', true)
      .order('year', { ascending: false }));
    list.innerHTML = rows.length ? rows.map((row) => `<article class="operations-card">
      <p class="section-index">${row.year} / ARCHIVE</p><h2>${escapeHtml(row.title)}</h2>
      <p>${escapeHtml(editionDateRange(row))} · ${escapeHtml(row.venue || '장소 기록 없음')}</p>
      ${row.summary ? `<p>${escapeHtml(row.summary)}</p>` : ''}
      <a class="operations-button secondary" href="./edition.html?year=${row.year}">${row.year} 학회 기록 보기 →</a>
    </article>`).join('') : '<div class="operations-empty">아직 공개된 지난 학회 기록이 없습니다. 종료된 학회의 공개 범위를 검토한 뒤 이곳에 보관합니다.</div>';
    message.textContent = rows.length ? `${rows.length}개 학회 기록을 볼 수 있습니다.` : '종료된 학회는 공개 승인 후 아카이브에 표시됩니다.';
  } catch {
    message.textContent = '지난 학회 기록을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.';
    message.classList.add('error');
  }
}
start();
