# Third-party notices

## Web dependencies and data

The application resolves dependencies through [web/package-lock.json](../web/package-lock.json).
JOB uses PDF.js (`pdfjs-dist` 6.3.289,
Apache-2.0), Mammoth 1.13.0 (BSD-2-Clause), and `cities.json` 1.1.65 (CC-BY-4.0).
The installed packages retain their upstream license files. PDF/DOCX parsing
and the city catalog run on the local server and are not included in the client
bundle.

City records originate in the [GeoNames Gazetteer](https://www.geonames.org/)
via [lutangar/cities.json](https://github.com/lutangar/cities.json), licensed
under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/).
Kontrol derives stable IDs, English country labels and a normalized search index
from those records; upstream dataset files remain unchanged. Attribution and
license links are visible beside city search.

Job cards retain the retrieved offer URL and source label. The JOB page links
back to [Remotive](https://remotive.com/) and [Arbeitnow](https://www.arbeitnow.com/).
The relevant provider terms and source limits are documented in the
[web guide](web-app.md#job-cv-to-matching-offers).
