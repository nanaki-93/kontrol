import { createHash } from 'node:crypto';
import { z } from 'zod';
import type { City } from '../../shared/jobs';

const normalize = (text: string) => text.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().trim();
type Entry = { city: City; name: string; qualifier: string[] };
let catalog: Promise<Entry[]> | undefined;
function cityCatalog(): Promise<Entry[]> {
  if (!catalog) catalog = Promise.all([import('cities.json', { with: { type: 'json' } }), import('cities.json/admin1', { with: { type: 'json' } })])
    .then(([cities, divisions]) => {
      const regions = new Map(divisions.default.map(region => [region.code, region.name]));
      const names = new Intl.DisplayNames(['en'], { type: 'region' }), countries = new Map<string, string>();
      return cities.default.map(value => {
        const country = countries.get(value.country) ?? names.of(value.country) ?? value.country;
        countries.set(value.country, country);
        const region = regions.get(value.country + '.' + value.admin1) ?? '';
        const city: City = { id: 'geo:' + createHash('sha256').update([value.country, value.admin1, value.name, value.lat, value.lng].join('|')).digest('hex').slice(0, 16),
          name: value.name, country, countryCode: value.country, region };
        return { city, name: normalize(value.name), qualifier: [country, value.country, region, value.admin1].map(normalize) };
      });
    }).catch(error => { catalog = undefined; throw error; });
  return catalog;
}
// The catalog lives on the server. City names and regions never need a remote
// geocoder, and the browser receives only the small matching result set.
export async function searchCities(query: string): Promise<City[]> {
  const term = z.string().trim().min(2).max(100).parse(query);
  const [needle, qualifier = ''] = term.split(',').map(normalize);
  if (needle.length < 2) return [];
  const rows = (await cityCatalog()).filter(row => row.name.includes(needle) &&
    (!qualifier || row.qualifier.some(value => value === qualifier || value.startsWith(qualifier))));
  const rank = (entry: Entry) => entry.name === needle ? 0 : entry.name.startsWith(needle) ? 1 : 2;
  return rows.sort((a, b) => rank(a) - rank(b) || a.name.length - b.name.length ||
    a.city.country.localeCompare(b.city.country) || a.city.region.localeCompare(b.city.region)).slice(0, 12).map(row => row.city);
}
