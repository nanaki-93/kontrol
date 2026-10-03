import test from 'node:test';
import assert from 'node:assert/strict';
import { MAX_CV_BYTES, JOB_ANALYSIS_TIMEOUT_MS, defaultJobPreferences, matchesJobFilters, jobPreferencesSchema, jobProfileSchema } from '../shared/jobs';
import { extractCV } from '../server/jobs/cv';
import { profilePrompt, matchingPrompt, parseProfile, parseJobMatches, jobAI } from '../server/jobs/ai';
import { parseJobPostings, parseRemotive, parseArbeitnow, publicJobURL, jobQueries, parseJobSearchLinks, jobListingLinks, jobBoardIndexes, createJobDiscovery } from '../server/jobs/sources';
import { searchCities } from '../server/jobs/cities';
import { jobSearchPrompt, piJobSearch } from '../server/jobs/search';
import { berlin, tokyo, profile, job, jobNow, cvText, cvUpload, pdfFixture, docxFixture } from './jobs-fixtures';

test('CV extraction reads TXT, real PDF and DOCX fixtures without retaining binary files', async () => {
  for (const [name, buffer] of [['fixture.pdf', pdfFixture()], ['fixture.docx', docxFixture()], ['fixture.txt', Buffer.from(cvText)]] as const) {
    const cv = await extractCV({ name, base64: buffer.toString('base64') }, jobNow);
    assert.match(cv.text, /Backend engineer/); assert.match(cv.text, /PostgreSQL/);
    assert.equal(cv.bytes, buffer.length); assert.equal(cv.uploadedAt, new Date(jobNow).toISOString());
    assert.deepEqual(Object.keys(cv).sort(), ['bytes', 'name', 'text', 'uploadedAt']);
  }
});
test('CV extraction accepts a readable PDF at the advertised upload limit', async () => {
  const pdf = pdfFixture();
  const bytes = Buffer.concat([pdf, Buffer.from('\n%'), Buffer.alloc(MAX_CV_BYTES - pdf.length - 2, 32)]);
  const cv = await extractCV({ name: 'large-fixture.pdf', base64: bytes.toString('base64') }, jobNow);
  assert.equal(cv.bytes, MAX_CV_BYTES);
  assert.match(cv.text, /Backend engineer/);
  for (const base64 of ['AAA', 'A===', 'AA=A', 'AAAA=', 'AAAA\n', 'AA?=']) {
    await assert.rejects(extractCV({ name: 'invalid.txt', base64 }));
  }
});
test('CV extraction rejects empty, scanned, corrupt, unsupported, binary and oversized inputs', async () => {
  const invalid = [
    { name: '../secret.txt', base64: cvUpload.base64 }, { name: 'file.doc', base64: cvUpload.base64 },
    { name: 'file.pdf', base64: cvUpload.base64 }, { name: 'file.pdf', base64: pdfFixture('').toString('base64') },
    { name: 'file.docx', base64: cvUpload.base64 }, { name: 'file.txt', base64: '!!!!!!' },
    { name: 'file.txt', base64: Buffer.from('Too little text').toString('base64') },
    { name: 'file.txt', base64: Buffer.from(cvText + '\0').toString('base64') },
    { name: 'file.txt', base64: Buffer.from('x'.repeat(60_001)).toString('base64') },
    { name: 'file.txt', base64: Buffer.alloc(5 * 1024 * 1024 + 1, 65).toString('base64') },
  ];
  for (const input of invalid) await assert.rejects(extractCV(input));
  const oversizedZip = docxFixture(), index = oversizedZip.indexOf(Buffer.from([0x50, 0x4b, 0x01, 0x02]));
  oversizedZip.writeUInt32LE(40 * 1024 * 1024, index + 24);
  await assert.rejects(extractCV({ name: 'large.docx', base64: oversizedZip.toString('base64') }), /expands beyond/);
});
test('filters separate part-time from work mode, enforce city and country, and reject expired postings', () => {
  const preferences = { ...defaultJobPreferences, cities: [berlin], workModes: ['hybrid'] as const };
  const filters = { ...preferences, workModes: [...preferences.workModes] };
  assert.equal(matchesJobFilters(job, filters, jobNow), true);
  assert.equal(matchesJobFilters(job, { ...filters, cities: [tokyo] }, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, cities: [{ name: 'Berlin', country: 'US' }] }, filters, jobNow), false);
  assert.equal(matchesJobFilters(job, { ...filters, employmentTypes: ['part_time'] }, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, employmentTypes: ['part_time'] }, { ...filters, employmentTypes: ['part_time'] }, jobNow), true);
  assert.equal(matchesJobFilters({ ...job, expiresAt: '2026-10-01T00:00:00.000Z' }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, publishedAt: '2020-10-01T00:00:00.000Z' }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, publishedAt: '2030-10-01T00:00:00.000Z' }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, workMode: 'unknown' }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...job, workMode: 'unknown', publishedAt: null }, defaultJobPreferences, jobNow), true);
  assert.equal(jobPreferencesSchema.safeParse({ ...filters, workModes: [] }).success, false);
  assert.equal(jobPreferencesSchema.safeParse({ ...filters, cities: [berlin, berlin] }).success, false);
});
test('remote does not imply worldwide eligibility or unrestricted country access', () => {
  const remote = { ...job, workMode: 'remote' as const };
  const filters = { ...defaultJobPreferences, cities: [tokyo] };
  assert.equal(matchesJobFilters(remote, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...remote, remoteRegions: ['Germany'] }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...remote, remoteRegions: ['JP'] }, filters, jobNow), true);
  assert.equal(matchesJobFilters({ ...remote, remoteRegions: ['Worldwide'] }, filters, jobNow), true);
  assert.equal(matchesJobFilters({ ...remote, remoteRegions: ['USA'] }, { ...filters, cities: [{ ...berlin, name: 'New York', country: 'United States', countryCode: 'US' }] }, jobNow), true);
  assert.equal(matchesJobFilters({ ...remote, remoteRegions: ['UK'] }, { ...filters, cities: [{ ...berlin, name: 'London', country: 'United Kingdom', countryCode: 'GB' }] }, jobNow), true);
});
test('Italian Milano listings match Milan without accepting other cities or countries', () => {
  const milan = { ...berlin, name: 'Milan', country: 'Italy', countryCode: 'IT', region: 'Lombardy' };
  const filters = { ...defaultJobPreferences, cities: [milan] };
  const source = { ...job, cities: [{ name: 'Milano', country: 'IT' }] };
  assert.equal(matchesJobFilters(source, filters, jobNow), true);
  assert.equal(matchesJobFilters(source, { ...filters, cities: [{ ...milan, name: 'Milano' }] }, jobNow), true);
  assert.equal(matchesJobFilters({ ...source, cities: [{ name: 'Milan', country: 'Italy' }] }, filters, jobNow), true);
  for (const name of ['Milano, Italy', 'Milan, IT']) {
    assert.equal(matchesJobFilters({ ...source, cities: [{ name, country: 'IT' }] }, filters, jobNow), true);
  }
  for (const name of ['Milano, Japan', 'Milano, Rome', 'Milano, Lombardy']) {
    assert.equal(matchesJobFilters({ ...source, cities: [{ name, country: 'IT' }] }, filters, jobNow), false);
  }
  assert.equal(matchesJobFilters({ ...source, cities: [{ name: 'Milano', country: 'US' }] }, filters, jobNow), false);
  assert.equal(matchesJobFilters({ ...source, cities: [{ name: 'Rome', country: 'IT' }] }, filters, jobNow), false);
  assert.equal(matchesJobFilters(source, { ...filters, cities: [{ ...milan, name: 'Rome' }] }, jobNow), false);
});
test('profile and matching contracts limit evidence, reject hallucinated source IDs and keep source fields authoritative', async () => {
  assert.deepEqual(parseProfile('```json\n' + JSON.stringify(profile) + '\n```'), profile);
  assert.throws(() => parseProfile('{"skills":["Invented"]}'), /complete profile/);
  assert.throws(() => parseProfile('not JSON'), /unreadable/);
  assert.equal(JSON.parse(profilePrompt(cvText)).cvText, cvText);
  assert.equal(matchingPrompt(profile, defaultJobPreferences, [job]).includes('Fixture Candidate'), false);
  const result = { id: job.id, score: 80, reason: 'Relevant Go experience.', gaps: [] };
  const matches = parseJobMatches(JSON.stringify({ matches: [result, result, { ...result, id: 'invented' }] }), [job], defaultJobPreferences, jobNow);
  assert.equal(matches.length, 1); assert.equal(matches[0].url, job.url); assert.equal(matches[0].title, job.title);
  assert.throws(() => parseJobMatches(JSON.stringify({ matches: [{ ...result, id: 'invented' }] }), [job], defaultJobPreferences, jobNow), /source and filter/);
  assert.throws(() => parseJobMatches(JSON.stringify({ matches: [{ ...result, score: 101 }] }), [job], defaultJobPreferences, jobNow), /invalid job/);
  assert.deepEqual(parseJobMatches('{"matches":[]}', [job], defaultJobPreferences, jobNow), []);
  let calls = 0;
  const ai = jobAI({ run: async () => { calls++; return '{"matches":[]}'; } });
  assert.deepEqual(await ai.rank(profile, defaultJobPreferences, [], jobNow, new AbortController().signal), []); assert.equal(calls, 0);
});
test('analysis accepts extra distinct skills and roles without relaxing stored profile validation', async () => {
  const answer = { ...profile, roles: Array.from({ length: 7 }, (_, i) => 'Role ' + i),
    skills: [' Go ', 'go', ...Array.from({ length: 40 }, (_, i) => 'Skill ' + i)], languages: ['English', ' English '] };
  assert.equal(jobProfileSchema.safeParse(answer).success, false);
  let calls = 0;
  const signal = new AbortController().signal;
  const ai = jobAI({ run: async (prompt, options, receivedSignal) => {
    calls++;
    const contract = JSON.parse(prompt).responseSchema;
    assert.equal(contract.properties.skills.maxItems, 30); assert.equal(contract.properties.roles.maxItems, 5);
    assert.equal(contract.properties.languages.maxItems, 10); assert.equal(contract.properties.headline.maxLength, 200);
    assert.equal(contract.properties.summary.maxLength, 1500); assert.equal(contract.properties.experience.maxLength, 1500);
    assert.equal(options?.timeoutMs, JOB_ANALYSIS_TIMEOUT_MS); assert.equal(receivedSignal, signal);
    return JSON.stringify(answer);
  } });
  const result = await ai.analyze(cvText, signal);
  assert.equal(calls, 1); assert.equal(result.skills.length, 30); assert.equal(result.roles.length, 5);
  assert.deepEqual(result.skills, ['Go', ...answer.skills.slice(2, 31)]);
  assert.deepEqual(result.languages, ['English']); assert.equal(result.summary, profile.summary);
  assert.equal(jobProfileSchema.safeParse(result).success, true);
  for (const skills of [[], [''], ['x'.repeat(201)], [123], 'Go', Array(201).fill('Go')]) {
    assert.throws(() => parseProfile(JSON.stringify({ ...profile, skills })), /required format.*CV is still saved/);
  }
});
const posting = { '@type': 'JobPosting', title: job.title, hiringOrganization: { name: job.company }, description: job.description,
  jobLocation: { address: { addressLocality: 'Berlin', addressCountry: 'DE' } }, employmentType: 'FULL_TIME', datePosted: '2026-10-01', validThrough: '2026-11-01' };
const html = (value: unknown) => '<script type="application/ld+json">' + JSON.stringify(value) + '</script>';
test('web parser accepts single structured postings, strips markup, and ignores articles and job directories', () => {
  const [source] = parseJobPostings(html({ '@graph': [posting] }), job.url + '?utm_source=fixture');
  assert.equal(source.url, job.url); assert.equal(source.workMode, 'hybrid'); assert.deepEqual(source.employmentTypes, ['full_time']);
  assert.equal(source.expiresAt, '2026-11-01T00:00:00.000Z');
  assert.deepEqual(parseJobPostings(html({ '@type': 'NewsArticle', headline: 'Jobs in Berlin' }), job.url), []);
  assert.deepEqual(parseJobPostings(html([posting, posting]), job.url), []);
  assert.deepEqual(parseJobPostings('<p>Job search results</p>', job.url), []);
  for (const url of ['file:///tmp/private', 'http://localhost/secret', 'http://127.0.0.1/a', 'https://192.168.1.1/', 'https://user:secret@example.com/', 'http://[::1]/']) assert.throws(() => publicJobURL(url));
});
test('Remotive normalizes employment, source attribution, dates and geographic restrictions', () => {
  const [source] = parseRemotive(JSON.stringify({ jobs: [{ url: 'https://remotive.com/remote-jobs/test', title: 'Engineer', company_name: 'Example', description: '<p>Go APIs</p>', job_type: 'part_time', publication_date: '2026-10-01T10:00:00', candidate_required_location: 'Japan, Germany' }] }));
  assert.equal(source.source, 'Remotive'); assert.equal(source.workMode, 'remote'); assert.equal(source.description, 'Go APIs');
  assert.equal(source.publishedAt, '2026-10-01T10:00:00.000Z');
  assert.deepEqual(source.employmentTypes, ['part_time']); assert.deepEqual(source.remoteRegions, ['Japan', 'Germany']);
  assert.throws(() => parseRemotive('{}'));
});
test('Arbeitnow uses source work arrangement and city/country metadata without inventing a country', () => {
  const row = { url: job.url, title: job.title, company_name: job.company, description: 'Build Go APIs.', remote: false,
    job_types: ['Part-time'], location: 'Berlin, DE', created_at: jobNow / 1000 };
  const [office, hybrid, missingCountry] = parseArbeitnow(JSON.stringify({ data: [row, { ...row, description: 'Hybrid role building Go APIs.' }, { ...row, location: 'Berlin' }] }));
  assert.equal(office.workMode, 'office'); assert.equal(office.source, 'Arbeitnow');
  assert.deepEqual(office.cities, [{ name: 'Berlin', country: 'DE' }]); assert.deepEqual(office.employmentTypes, ['part_time']);
  assert.equal(hybrid.workMode, 'hybrid'); assert.equal(missingCountry.cities[0].country, '');
  assert.equal(matchesJobFilters(missingCountry, { ...defaultJobPreferences, cities: [berlin] }, jobNow), false);
});
test('offline city search handles country and region qualifiers, accents and stable IDs', async () => {
  const cities = await searchCities('Tokyo, Japan');
  assert.equal(cities[0].name, 'Tokyo'); assert.equal(cities[0].countryCode, 'JP'); assert.match(cities[0].id, /^geo:/);
  assert.equal((await searchCities('Berlin, DE'))[0].countryCode, 'DE');
  assert.equal((await searchCities('Paris, Texas'))[0].region, 'Texas');
  assert.equal((await searchCities('Sao Paulo, Brazil'))[0].name, 'São Paulo');
  assert.equal((await searchCities('Tokyo, Japan'))[0].id, cities[0].id);
  assert.deepEqual(await searchCities('NoSuchCityFixture'), []);
  await assert.rejects(searchCities('T'));
});
test('discovery deduplicates structured listings, covers selected cities and caches Remotive', async () => {
  let remoteCalls = 0;
  const discover = createJobDiscovery(async url => {
    if (url.includes('remotive.com/api')) { remoteCalls++; return '{"jobs":[]}'; }
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url.includes('bing.com/search')) return '<rss><channel><item><title>Backend engineer</title><link>' + job.url + '</link></item></channel></rss>';
    return html(posting);
  });
  const filters = { ...defaultJobPreferences, cities: [berlin] };
  assert.equal((await discover(profile, filters, jobNow, new AbortController().signal)).sources.length, 1);
  assert.equal((await discover(profile, filters, jobNow + 1000, new AbortController().signal)).sources.length, 1); assert.equal(remoteCalls, 1);
  assert.ok(jobQueries(profile, { ...filters, cities: [berlin, tokyo], employmentTypes: ['part_time'] }).some(query => query.includes('Tokyo Japan') && query.includes('part time')));
  const failed = createJobDiscovery(async () => { throw new Error('private failure'); });
  await assert.rejects(failed(profile, defaultJobPreferences, jobNow, new AbortController().signal), /Job sources could not be reached/);
});
test('a cached board duplicate cannot revive a posting whose page states that it expired', async () => {
  const discover = createJobDiscovery(async url => {
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return JSON.stringify({ data: [{ url: job.url, title: job.title, company_name: job.company,
      description: 'Hybrid work in Berlin.', remote: false, job_types: ['full_time'], location: 'Berlin, DE', created_at: jobNow / 1000 }] });
    if (url.includes('bing.com/search')) return '<rss><channel><item><title>Engineer</title><link>' + job.url + '</link></item></channel></rss>';
    return html({ ...posting, validThrough: '2026-09-30' });
  });
  const result = await discover(profile, defaultJobPreferences, jobNow, new AbortController().signal);
  assert.deepEqual(result.sources, []);
});

test('Tokyo filters include explicitly located special wards without broadening other city filters', () => {
  const [source] = parseJobPostings(html({ ...posting, jobLocation: { address: {
    addressLocality: 'Minato-ku', addressRegion: 'Tokyo', addressCountry: 'JP',
  } } }), job.url);
  assert.deepEqual(source.cities, [{ name: 'Minato-ku', region: 'Tokyo', country: 'JP' }]);
  assert.equal(source.location, 'Minato-ku, Tokyo, JP');
  assert.equal(matchesJobFilters(source, { ...defaultJobPreferences, cities: [tokyo] }, jobNow), true);
  for (const city of [
    { name: 'Minato-ku', country: 'JP' }, { name: 'Minato-ku', country: 'US', region: 'Tokyo' },
    { name: 'Minato-ku', country: 'JP', region: 'Osaka' }, { name: 'Hachioji', country: 'JP', region: 'Tokyo' },
  ]) assert.equal(matchesJobFilters({ ...source, cities: [city] }, { ...defaultJobPreferences, cities: [tokyo] }, jobNow), false);
  const newYork = { ...tokyo, name: 'New York', country: 'United States', countryCode: 'US', region: 'New York' };
  assert.equal(matchesJobFilters({ ...source, cities: [{ name: 'Albany', country: 'US', region: 'New York' }] }, { ...defaultJobPreferences, cities: [newYork] }, jobNow), false);
});
const searchLink = (url: string, title = 'Backend jobs') => '<a class="result__a" href="//duckduckgo.com/l/?uddg=' + encodeURIComponent(url) + '">' + title + '</a>';
test('fallback search unwraps only organic public destinations and does not follow ads or private URLs', () => {
  const endpoint = 'https://html.duckduckgo.com/html/?q=backend';
  const links = parseJobSearchLinks(searchLink(job.url) + searchLink(job.url + '?utm_source=search') + searchLink('http://127.0.0.1/private') +
    '<a class="result__a" href="https://duckduckgo.com/y.js?ad_provider=bing">Sponsored job</a>' +
    '<a href="https://example.com/navigation">Backend engineer</a>', endpoint);
  assert.deepEqual(links, [{ url: job.url, title: 'Backend jobs' }]);
  assert.throws(() => parseJobSearchLinks('<form id="challenge-form">Challenge</form>', endpoint), /challenge/);
});
test('directory links prioritize relevant roles, stay on the source site and require retrieved posting evidence', () => {
  const links = jobListingLinks('<a href="/companies/acme/jobs/backend">Backend Engineer</a>' +
    '<a href="/companies/acme/jobs/backend?utm_source=board">Backend Engineer</a>' +
    '<a href="/jobs/sales">Sales Associate</a><a href="/articles/backend">Backend engineering guide</a>' +
    '<a href="https://other.example/jobs/backend">Backend Engineer</a>' +
    '<a href="http://localhost/jobs/backend">Backend Engineer</a>', 'https://example.com/jobs', profile);
  assert.deepEqual(links, [{ url: 'https://example.com/companies/acme/jobs/backend', title: 'Backend Engineer' }]);
  const italian = jobListingLinks('<a href="/lavoro/61521/java-back-end-milano">Java back end</a>' +
    '<a href="/lavoro/61521/java-back-end-milano">Vedi i dettagli</a>' +
    '<a href="/offerte-di-lavoro/milano">Backend jobs</a><a href="https://other.example/lavoro/private">Backend job</a>',
  'https://example.com/offerte-di-lavoro/milano', profile);
  assert.deepEqual(italian, [{ url: 'https://example.com/lavoro/61521/java-back-end-milano', title: 'Java back end' }]);
});
test('direct board coverage follows the selected geography and software profile', () => {
  assert.equal(jobBoardIndexes(profile, { ...defaultJobPreferences, cities: [tokyo] }).length, 1);
  assert.deepEqual(jobBoardIndexes(profile, { ...defaultJobPreferences, cities: [berlin] }), []);
  assert.deepEqual(jobBoardIndexes({ ...profile, roles: ['Nurse'], skills: ['Patient care'] }, { ...defaultJobPreferences, cities: [tokyo] }), []);
});
for (const searchResult of ['empty', 'unavailable', 'blocked', 'unstructured']) test(`direct boards return fresh offers when PI discovery is ${searchResult}`, async () => {
  const calls: string[] = [];
  const milan = { ...berlin, name: 'Milan', country: 'Italy', countryCode: 'IT', region: 'Lombardy' };
  const offers = ['https://www.tokyodev.com/companies/fixture/jobs/backend', 'https://reteinformaticalavoro.it/lavoro/61521/java-back-end-milano'];
  const discover = createJobDiscovery(async url => {
    calls.push(url);
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url === 'https://www.tokyodev.com/jobs/backend') return '<a href="/companies/fixture/jobs/backend">Backend engineer</a>';
    if (url === 'https://reteinformaticalavoro.it/offerte-di-lavoro/milano') return '<a href="/lavoro/61521/java-back-end-milano">Java back end</a><a href="/lavoro/old">Backend engineer</a>';
    if (url === offers[0]) return html({ ...posting, jobLocation: { address: { addressLocality: 'Tokyo', addressCountry: 'JP' } } });
    if (url === offers[1] || url.endsWith('/lavoro/old')) return html({ ...posting,
      datePosted: url.endsWith('/old') ? '2020-01-01' : '2026-10-01',
      jobLocation: { address: { addressLocality: 'Milano, Italy', addressCountry: 'IT' } },
    });
    if (url === 'https://search.example/jobs/unreadable' && searchResult === 'unstructured') return '<p>No structured posting.</p>';
    throw new Error('PRIVATE-SOURCE-ERROR');
  }, async () => {
    if (searchResult === 'unavailable') throw new Error('PRIVATE-PI-ERROR');
    return searchResult === 'empty' ? [] : [{ url: 'https://search.example/jobs/unreadable', title: 'Backend engineer' }];
  });
  const result = await discover(profile, { ...defaultJobPreferences, cities: [tokyo, milan], employmentTypes: ['full_time'] }, jobNow, new AbortController().signal);
  assert.deepEqual(result.sources.map(source => source.url).sort(), offers.sort());
  assert.equal(calls.filter(url => url === offers[0]).length, 1);
  assert.equal(calls.filter(url => url === offers[1]).length, 1);
  assert.equal(calls.some(url => /bing\.com|duckduckgo\.com/.test(url)), false);
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE|no readable job postings/);
});
for (const bingFails of [false, true]) test(`discovery recovers from ${bingFails ? 'unavailable' : 'irrelevant'} Bing results through a job board and a structured offer`, async () => {
  const calls: string[] = [], offer = 'https://board.example/companies/acme/jobs/backend';
  const discover = createJobDiscovery(async url => {
    calls.push(url);
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url.includes('bing.com/search')) {
      if (bingFails) throw new Error('Fixture unavailable');
      return '<rss><channel><item><title>Backend tutorial</title><link>https://example.com/tutorial</link></item></channel></rss>';
    }
    if (url.includes('duckduckgo.com/html')) return searchLink('https://board.example/jobs');
    if (url === 'https://board.example/jobs') return '<a href="/companies/acme/jobs/backend">Backend Software Engineer</a>';
    if (url === offer) return html({ ...posting, jobLocation: { address: { addressLocality: 'Shibuya-ku', addressRegion: 'Tokyo', addressCountry: 'JP' } } });
    return '<p>Backend tutorials are not job offers.</p>';
  });
  const result = await discover(profile, { ...defaultJobPreferences, employmentTypes: ['full_time'], cities: [tokyo] }, jobNow, new AbortController().signal);
  assert.deepEqual(result.sources.map(source => source.url), [offer]);
  assert.equal(calls.filter(url => url === offer).length, 1);
  assert.ok(calls.some(url => url.includes('duckduckgo.com/html')));
});
test('discovery reports unreadable coverage, preserves strict filters and follows directories for only one level', async () => {
  const calls: string[] = [];
  const discover = createJobDiscovery(async url => {
    calls.push(url);
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url.includes('bing.com/search')) return '<rss><channel /></rss>';
    if (url.includes('duckduckgo.com/html')) return searchLink('https://board.example/jobs');
    if (url === 'https://board.example/jobs') return '<a href="/jobs/backend">Backend Engineer</a><a href="/jobs/engineer">Software Engineer</a>';
    if (url === 'https://board.example/jobs/backend') return '<a href="/jobs/backend/deep">Backend Engineer</a>';
    return html(posting); // Berlin does not match Tokyo.
  });
  const result = await discover(profile, { ...defaultJobPreferences, cities: [tokyo] }, jobNow, new AbortController().signal);
  assert.deepEqual(result.sources, []);
  assert.ok(result.warnings.some(warning => /no readable job postings matching your filters/.test(warning)));
  assert.equal(calls.includes('https://board.example/jobs/backend/deep'), false);
});
test('PI search uses roles and skills and accepts only URLs grounded in public provider evidence', async () => {
  const prompt = JSON.parse(jobSearchPrompt({ ...profile, summary: 'PRIVATE-SUMMARY', experience: 'PRIVATE-EXPERIENCE' }, { ...defaultJobPreferences, cities: [tokyo] }, jobNow));
  assert.deepEqual(prompt.roles, profile.roles); assert.deepEqual(prompt.skills, profile.skills);
  assert.deepEqual(prompt.preferences.cities, [{ name: 'Tokyo', country: 'Japan' }]);
  assert.doesNotMatch(JSON.stringify(prompt), /PRIVATE|Fixture Candidate|1850147/);
  const link = { url: job.url, title: job.title };
  const run: Parameters<typeof piJobSearch>[0] = { run: async () => ({ text: JSON.stringify({ links: [link,
    { ...link, url: job.url + '?utm_source=search' }, { ...link, url: 'https://invented.example/jobs/backend' },
    { ...link, url: 'http://127.0.0.1/private' },
  ] }), urls: [job.url, 'http://127.0.0.1/private'] }) };
  assert.deepEqual(await piJobSearch(run)(profile, defaultJobPreferences, jobNow, new AbortController().signal), [link]);
  const ungrounded = piJobSearch({ run: async () => ({ text: JSON.stringify({ links: [link] }), urls: [] }) });
  await assert.rejects(ungrounded(profile, defaultJobPreferences, jobNow, new AbortController().signal), /backed by web-search evidence/);
});
test('PI-discovered links retrieve real postings before ranking and avoid scraping search engines on success', async () => {
  const calls: string[] = [];
  const discover = createJobDiscovery(async url => {
    calls.push(url);
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url === job.url) return html(posting);
    throw new Error('Search-engine scraping should not be needed');
  }, async () => [{ url: job.url, title: job.title }]);
  const result = await discover(profile, { ...defaultJobPreferences, cities: [berlin] }, jobNow, new AbortController().signal);
  assert.equal(result.sources.length, 1); assert.equal(result.sources[0].url, job.url);
  assert.deepEqual(result.warnings, []);
  assert.equal(calls.some(url => /bing|duckduckgo/.test(url)), false);
});
test('PI discovery failure is sanitized and falls back to verified public listings', async () => {
  const discover = createJobDiscovery(async url => {
    if (url.includes('remotive.com/api')) return '{"jobs":[]}';
    if (url.includes('arbeitnow.com/api')) return '{"data":[]}';
    if (url.includes('bing.com/search')) return '<rss><channel><item><title>Backend engineer</title><link>' + job.url + '</link></item></channel></rss>';
    return html(posting);
  }, async () => { throw new Error('PRIVATE-PROVIDER-ERROR'); });
  const result = await discover(profile, defaultJobPreferences, jobNow, new AbortController().signal);
  assert.equal(result.sources.length, 1);
  assert.match(result.warnings.join(' '), /PI web search could not finish/);
  assert.doesNotMatch(JSON.stringify(result), /PRIVATE/);
});
