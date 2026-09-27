import { conferenceClient, editionDateRange, escapeHtml, requireData } from './conference-client.js';

async function start() {
  const message = document.querySelector('#edition-message');
  const content = document.querySelector('#edition-content');
  const rawYear = new URLSearchParams(location.search).get('year');
  if (rawYear && !/^20\d{2}$/.test(rawYear)) {
    message.textContent = '학회 연도를 확인해 주세요.';
    message.classList.add('error');
    return;
  }
  try {
    const client = await conferenceClient();
    const query = client.from('conference_editions')
      .select('year,title,start_date,end_date,venue,summary,status,archive_published,proceedings_url');
    const row = requireData(await (rawYear ? query.eq('year', Number(rawYear)) : query.eq('status', 'current')).single());
    // RLS hides unpublished archives from anonymous readers; do not expose a draft preview here.
    if (row.status === 'draft' || (row.status === 'archived' && !row.archive_published)) {
      throw new Error('공개되지 않은 학회입니다.');
    }
    document.title = `${row.title} | Co-R&BD Conference`;
    document.querySelector('#edition-label').textContent = row.status === 'archived' ? `${row.year} / ARCHIVE` : `${row.year} / CURRENT CONFERENCE`;
    document.querySelector('#edition-title').textContent = row.title;
    document.querySelector('#edition-summary').textContent = row.summary || (row.status === 'archived'
      ? '공개가 승인된 학회 기록입니다.' : '세부 안내는 확정되는 대로 이곳에 게시합니다.');
    const active = row.status === 'current';
    content.innerHTML = `<section class="operations-card"><h2>행사 정보</h2>
      <p><strong>일정</strong><br>${escapeHtml(editionDateRange(row))}</p>
      <p><strong>장소</strong><br>${escapeHtml(row.venue || '장소 확정 전')}</p>
      ${row.proceedings_url ? `<p><a href="${escapeHtml(row.proceedings_url)}" target="_blank" rel="noopener noreferrer">공개 자료집 보기 ↗</a></p>` : ''}
    </section><section class="operations-card"><h2>${active ? '참여 안내' : '공개 기록'}</h2>
      <p>${active ? '현재 학회의 투고·심사, 참가 신청 및 확정 프로그램을 확인할 수 있습니다.' : '공개가 승인된 세션과 연사만 확인할 수 있습니다.'}</p>
      <div class="operations-actions">
        <a class="operations-button secondary" href="./program.html?year=${row.year}">프로그램 보기</a>
        ${active ? '<a class="operations-button secondary" href="./submission.html">논문 투고·심사</a><a class="operations-button secondary" href="./registration.html">참가 신청</a>' : '<a class="operations-button secondary" href="./archive.html">지난 학회 목록</a>'}
      </div>
    </section>`;
    content.hidden = false;
    message.textContent = active ? '현재 학회 안내입니다.' : '지난 학회의 공개 기록입니다.';
  } catch {
    message.textContent = '공개된 학회 정보를 찾을 수 없습니다.';
    message.classList.add('error');
  }
}
start();
