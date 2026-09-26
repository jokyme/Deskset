# Place table of the weather plugins

`places.tsv` is the offline table the weather plugins (`Plugin=MacWeather`, `Plugin=MacSun`) look place names up in
(`Location=Oslo, NO`, `Springfield, IL`, `北京`), and find the nearest town of a coordinate in. No online geocoder is
used, so place names never leave the Mac. The app bundles it as `Contents/Resources/Places/places.tsv`
(`scripts/build-app.sh`); builds run from the repository read this copy.

## Source and licence

- GeoNames, <https://www.geonames.org/>, downloaded 2026-09-26 from <https://download.geonames.org/export/dump/>:
  `cities15000.txt` (every town with 15,000 people or more), `countryInfo.txt` (English country names) and
  `admin1CodesASCII.txt` (region names).
- Licence: Creative Commons Attribution 4.0 International (<https://creativecommons.org/licenses/by/4.0/>).
  Credit: "Place names from GeoNames". The data was changed (see below); GeoNames does not endorse Deskset.

## Format

UTF-8, one place per line, largest population first, fields separated by tabs:

```
name  asciiname  alternates(comma-separated)  latitude  longitude  country  admin1  population  timezone
```

Coordinates have two decimals (about 1 km). `admin1` is GeoNames' first-level region code (US states are their
abbreviations). After the places come `#country⇥CODE⇥English name`, `#admin1⇥CC.code⇥region name` and
`#meta⇥key⇥value` rows (source, licence, download date, number of places).

## Changes made to the GeoNames data

`scripts/make-places.swift` keeps, for each town: its name, ASCII name, coordinates, country, region, population and
time zone, and trims its alternate names: names that are web addresses, contain digits, are longer than 40
characters, are three- or four-letter capital codes (airport codes) or fold to the town's own name are dropped, as is
one former colonial-era name the script lists by its hash. Every
town keeps its alternates in the scripts of its country's languages and its Chinese names; the other alternates
(other scripts, spellings in other languages) are kept for the largest towns, as many as fit in 4 MB.

## Regenerating

```bash
curl -O https://download.geonames.org/export/dump/cities15000.zip && unzip cities15000.zip
curl -O https://download.geonames.org/export/dump/countryInfo.txt
curl -O https://download.geonames.org/export/dump/admin1CodesASCII.txt
swift scripts/make-places.swift <folder with the three files> <download date, YYYY-MM-DD>
```

The script prints the number of places and the file size (at most 4 MB); the same input gives the same file. Update
the download date above when the table is regenerated.
