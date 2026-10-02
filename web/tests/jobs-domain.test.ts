import test from 'node:test';
import assert from 'node:assert/strict';
import { JOB_ANALYSIS_TIMEOUT_MS, defaultJobPreferences, matchesJobFilters, jobPreferencesSchema, jobProfileSchema } from '../shared/jobs';
import { extractCV } from '../server/jobs/cv';
import { profilePrompt, matchingPrompt, parseProfile, parseJobMatches, jobAI } from '../server/jobs/ai';
import { parseJobPostings, parseRemotive, parseArbeitnow, publicJobURL, jobQueries, createJobDiscovery } from '../server/jobs/sources';
import { searchCities } from '../server/jobs/cities';
import { berlin, tokyo, profile, job, jobNow, cvText, cvUpload, pdfFixture, docxFixture } from './jobs-fixtures';

test('CV extraction reads TXT, real PDF and DOCX fixtures without retaining binary files', async () => {
  for (const [name, buffer] of [['fixture.pdf', pdfFixture()], ['fixture.docx', docxFixture()], ['fixture.txt', Buffer.from(cvText)]] as const) {
    const cv = await extractCV({ name, base64: buffer.toString('base64') }, jobNow);
    assert.match(cv.text, /Backend engineer/); assert.match(cv.text, /PostgreSQL/);
    assert.equal(cv.bytes, buffer.length); assert.equal(cv.uploadedAt, new Date(jobNow).toISOString());
    assert.deepEqual(Object.keys(cv).sort(), ['bytes', 'name', 'text', 'uploadedAt']);
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
