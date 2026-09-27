import { conferenceClient, currentEdition, editionDateRange, escapeHtml, kstDate, kstTime, requireData } from './conference-client.js';

const status = document.querySelector('#program-message');
const list = document.querySelector('#program-list');
const KINDS = {
  keynote: '기조강연', oral: '구두발표', poster: '포스터', panel: '토론',
  workshop: '워크숍', ceremony: '공식행사', networking: '교류', break: '휴식', other: '기타',
};

async function start() {
  try {
    const client = await conferenceClient();
    const yearParam = new URLSearchParams(location.search).get('year');
    if (yearParam && !/^20\d{2}$/.test(yearParam)) throw new Error('Invalid conference year');
    const edition = yearParam
      ? requireData(await client.from('conference_editions')
        .select('year,title,start_date,end_date,venue,status,archive_published').eq('year', Number(yearParam)).single())
      : await currentEdition(client);
    if (edition.status === 'draft' || (edition.status === 'archived' && !edition.archive_published)) {
      throw new Error('Conference program is not public');
    }
    document.title = `프로그램·연사 | ${edition.title}`;
    document.querySelector('#program-edition-label').textContent = `CO-R&BD ${edition.year} / PROGRAM`;
    document.querySelector('#program-intro').textContent = `${editionDateRange(edition)}, ${edition.venue || '장소 확정 전'}. 공개가 승인된 세션과 연사를 안내합니다.`;
    document.querySelector('#program-current-actions').hidden = edition.status !== 'current';
    document.querySelector('#program-archive-link').hidden = edition.status !== 'archived';
    document.querySelector('#program-cfp-link').hidden = edition.year !== 2026 || edition.status !== 'current';
    document.querySelector('#program-registration-link').hidden = edition.status !== 'current';
    document.querySelector('#program-submission-link').hidden = edition.status !== 'current';
    const sessions = requireData(await client.from('program_sessions')
      .select('id,title,session_type,starts_at,ends_at,room,description,moderator')
      .eq('edition_year', edition.year).eq('is_published', true).order('starts_at'));
    if (!sessions.length) {
      status.textContent = '공개된 세부 프로그램이 아직 없습니다.';
      list.innerHTML = '<div class="operations-empty">공개된 세션이 없습니다. 확정 후 날짜·시간·장소별로 안내합니다.</div>';
      return;
    }
    const links = requireData(await client.from('program_session_speakers')
      .select('session_id,speaker_id,sort_order').in('session_id', sessions.map((session) => session.id)));
    const speakerIds = [...new Set(links.map((link) => link.speaker_id))];
    const speakers = speakerIds.length
      ? requireData(await client.from('program_speakers').select('id,full_name,affiliation,bio')
        .eq('is_published', true).in('id', speakerIds))
      : [];
    const speakerMap = new Map(speakers.map((speaker) => [speaker.id, speaker]));
    const byDay = new Map();
    for (const session of sessions) {
      const day = kstDate(session.starts_at);
      if (!byDay.has(day)) byDay.set(day, []);
      byDay.get(day).push(session);
    }
    list.innerHTML = [...byDay].map(([day, rows]) => `<section class="operations-day" aria-label="${escapeHtml(day)}">
      <h2>${escapeHtml(day)}</h2>
      <div class="operations-card">${rows.map((row) => {
        const people = links.filter((link) => link.session_id === row.id).sort((a, b) => a.sort_order - b.sort_order)
          .map((link) => speakerMap.get(link.speaker_id)).filter(Boolean);
        return `<article class="operations-session"><time datetime="${escapeHtml(row.starts_at)}">${escapeHtml(kstTime(row.starts_at))}–${escapeHtml(kstTime(row.ends_at))}</time>
          <div><span class="operations-meta">${escapeHtml(KINDS[row.session_type] || '세션')} · ${escapeHtml(row.room)}</span>
          <h3>${escapeHtml(row.title)}</h3>${row.description ? `<p>${escapeHtml(row.description)}</p>` : ''}
          ${row.moderator ? `<p>좌장: ${escapeHtml(row.moderator)}</p>` : ''}
          ${people.length ? `<div class="operations-speakers">${people.map((person) => `<div class="operations-speaker"><strong>${escapeHtml(person.full_name)}</strong><span>${escapeHtml(person.affiliation)}</span>${person.bio ? `<p>${escapeHtml(person.bio)}</p>` : ''}</div>`).join('')}</div>` : ''}
          </div></article>`;
      }).join('')}</div></section>`).join('');
    status.textContent = '확정되어 공개된 세션만 표시합니다. 세부 일정은 변경될 수 있습니다.';
  } catch (error) {
    const preparing = error.code === 'PGRST205' || /could not find the table/i.test(error.message);
    status.textContent = preparing
      ? '확정 프로그램을 준비 중입니다. 세션과 연사는 확정 후 이곳에 공개합니다.'
      : '프로그램을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.';
    if (preparing) {
      list.innerHTML = '<div class="operations-empty">공개된 세션이 없습니다. 홈페이지의 1박 2일 일정은 운영 가안입니다.</div>';
    } else {
      status.classList.add('error');
    }
  }
}

start();
