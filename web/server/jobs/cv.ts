import { z } from 'zod';
import { MAX_CV_BYTES, MAX_CV_TEXT, cvSchema, type CV } from '../../shared/jobs';
import { HttpError } from '../errors';

const uploadSchema = z.object({
  name: z.string().trim().min(1).max(180).refine(name => !/[\\/\x00-\x1f]/.test(name), 'Use a filename without a path.'),
  base64: z.string().min(4).max(Math.ceil(MAX_CV_BYTES / 3) * 4).regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/),
});

// Inspect ZIP directory sizes before the DOCX parser inflates any member.
function checkDocxArchive(buffer: Buffer) {
  let end = -1;
  for (let i = buffer.length - 22; i >= Math.max(0, buffer.length - 65557); i--) {
    if (buffer.readUInt32LE(i) === 0x06054b50) { end = i; break; }
  }
  if (end < 0) throw new Error('Invalid archive');
  const count = buffer.readUInt16LE(end + 10), size = buffer.readUInt32LE(end + 12);
  let position = buffer.readUInt32LE(end + 16), expanded = 0;
  if (count > 1000 || position + size > end || buffer.readUInt16LE(end + 4) || buffer.readUInt16LE(end + 6)) throw new Error('Unsupported archive');
  for (let i = 0; i < count; i++) {
    if (position + 46 > end || buffer.readUInt32LE(position) !== 0x02014b50) throw new Error('Invalid member');
    expanded += buffer.readUInt32LE(position + 24);
    if (expanded > 30 * 1024 * 1024) throw new HttpError(413, 'The DOCX expands beyond 30 MB. Export a smaller CV or use plain text.');
    position += 46 + buffer.readUInt16LE(position + 28) + buffer.readUInt16LE(position + 30) + buffer.readUInt16LE(position + 32);
  }
}

export async function extractCV(input: unknown, now = Date.now()): Promise<CV> {
  const { name, base64 } = uploadSchema.parse(input), bytes = Buffer.from(base64, 'base64');
  if (!bytes.length || bytes.length > MAX_CV_BYTES) throw new HttpError(413, 'Choose a CV up to 5 MB.');
  const extension = name.split('.').at(-1)?.toLowerCase();
  if (!['pdf', 'docx', 'txt'].includes(extension ?? '')) throw new HttpError(400, 'Upload a PDF, DOCX or UTF-8 TXT CV.');
  let text: string;
  try {
    if (extension === 'txt') {
      text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
      if (/[\x00-\x08\x0e-\x1f]/.test(text)) throw new Error('Binary text');
    } else if (extension === 'docx') {
      checkDocxArchive(bytes);
      const mammoth = await import('mammoth');
      text = (await mammoth.extractRawText({ buffer: bytes })).value;
    } else {
      if (!bytes.subarray(0, 5).equals(Buffer.from('%PDF-'))) throw new Error('Not PDF');
      const { getDocument } = await import('pdfjs-dist/legacy/build/pdf.mjs');
      const task = getDocument({ data: new Uint8Array(bytes), useSystemFonts: false, disableFontFace: true, verbosity: 0 });
      try {
        const document = await task.promise;
        if (document.numPages > 25) throw new HttpError(400, 'Choose a CV with at most 25 pages.');
        const pages: string[] = [];
        for (let number = 1; number <= document.numPages; number++) {
          const page = await document.getPage(number), content = await page.getTextContent();
          pages.push(content.items.map(item => 'str' in item ? item.str + (item.hasEOL ? '\n' : ' ') : '').join(''));
          page.cleanup();
          if (pages.join('\n').length > MAX_CV_TEXT) throw new HttpError(400, 'The CV exceeds 60,000 text characters. Choose a shorter version.');
        }
        text = pages.join('\n\n');
      } finally { await task.destroy(); }
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new HttpError(400, 'The CV could not be read. Use an unprotected PDF, a valid DOCX, or UTF-8 TXT.');
  }
  text = text.replace(/\r\n?/g, '\n').replace(/\u0000/g, '').trim();
  if (text.length < 80) throw new HttpError(400, 'Not enough readable text was found. Scanned PDFs need OCR first; you can also upload a TXT CV.');
  if (text.length > MAX_CV_TEXT) throw new HttpError(400, 'The CV exceeds 60,000 text characters. Choose a shorter version.');
  return cvSchema.parse({ name, bytes: bytes.length, uploadedAt: new Date(now).toISOString(), text });
}
