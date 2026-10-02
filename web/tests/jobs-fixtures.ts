import type { City, JobProfile, JobSource } from '../shared/jobs';

export const jobNow = Date.parse('2026-10-02T06:00:00.000Z');
export const berlin: City = { id: '2950159', name: 'Berlin', region: 'Berlin', country: 'Germany', countryCode: 'DE' };
export const tokyo: City = { id: '1850147', name: 'Tokyo', region: 'Tokyo', country: 'Japan', countryCode: 'JP' };
export const profile: JobProfile = { headline: 'Backend engineer', summary: 'Builds reliable Go services.',
  roles: ['Backend engineer'], skills: ['Go', 'PostgreSQL'], experience: 'Five years building APIs.', languages: ['English'] };
export const cvText = 'Fixture Candidate\nBackend engineer with five years building reliable Go services and PostgreSQL databases. Experienced in API design, testing and distributed systems. Fluent in English.';
export const cvUpload = { name: 'fixture-cv.txt', base64: Buffer.from(cvText).toString('base64') };
export const job: JobSource = { id: 'source-1', url: 'https://example.com/jobs/backend', title: 'Backend engineer', company: 'Fixture Company',
  description: 'Build Go APIs and PostgreSQL services. Five years experience and English required. Full-time hybrid role in Berlin, Germany.',
  location: 'Berlin, Germany', cities: [{ name: 'Berlin', country: 'DE' }], remoteRegions: [], workMode: 'hybrid', employmentTypes: ['full_time'],
  salary: null, publishedAt: '2026-10-01T00:00:00.000Z', expiresAt: '2026-11-01T00:00:00.000Z', source: 'example.com' };
export const readyPI = async () => ({ configured: true, provider: 'pi' as const, model: 'PI fixture', message: 'Fixture only.' });
export const match = { ...job, score: 88, reason: 'Go and PostgreSQL experience fit the backend role.', gaps: ['Confirm hybrid attendance requirements.'] };

// Small synthetic documents exercise real parsers without personal files or GUI.
export function pdfFixture(text = cvText): Buffer {
  const content = 'BT /F1 12 Tf 30 700 Td (' + text.replace(/[\\()]/g, '\\$&').replaceAll('\n', ' ') + ') Tj ET';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', '<< /Length ' + Buffer.byteLength(content) + ' >>\nstream\n' + content + '\nendstream',
  ];
  let value = '%PDF-1.4\n';
  const offsets = objects.map((object, index) => { const offset = Buffer.byteLength(value); value += (index + 1) + ' 0 obj\n' + object + '\nendobj\n'; return offset; });
  const xref = Buffer.byteLength(value);
  value += 'xref\n0 6\n0000000000 65535 f \n' + offsets.map(offset => String(offset).padStart(10, '0') + ' 00000 n \n').join('');
  value += 'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + xref + '\n%%EOF';
  return Buffer.from(value);
}
function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  return (crc ^ 0xffffffff) >>> 0;
}
export function docxFixture(): Buffer {
  const files: Record<string, string> = {
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>' + cvText + '</w:t></w:r></w:p></w:body></w:document>',
  };
  const chunks: Buffer[] = [], directory: Buffer[] = []; let offset = 0;
  for (const [path, text] of Object.entries(files)) {
    const name = Buffer.from(path), data = Buffer.from(text), crc = crc32(data);
    const local = Buffer.alloc(30); local.writeUInt32LE(0x04034b50); local.writeUInt16LE(20, 4); local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(data.length, 18); local.writeUInt32LE(data.length, 22); local.writeUInt16LE(name.length, 26);
    const central = Buffer.alloc(46); central.writeUInt32LE(0x02014b50); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6);
    central.writeUInt32LE(crc, 16); central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(name.length, 28); central.writeUInt32LE(offset, 42);
    chunks.push(local, name, data); directory.push(central, name); offset += local.length + name.length + data.length;
  }
  const central = Buffer.concat(directory), end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(Object.keys(files).length, 8); end.writeUInt16LE(Object.keys(files).length, 10);
  end.writeUInt32LE(central.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...chunks, central, end]);
}
