# Weather and sun plugins (Deskset extensions)

Area `weather`: `Plugin=MacWeather` (forecasts from MET Norway) and `Plugin=MacSun` (sun and moon, worked out on the
Mac). Rainmeter has no weather plugin: Windows skins scrape weather web sites with WebParser. Both plugins are Deskset
extensions, so skins that use them work only on Deskset.

Code: `Sources/DesksetCore/Weather/*` (forecast model, MET Norway requests and parser, derived values, units,
conditions, sun and moon, place table, the shared `WeatherService`, the HTTPS transport),
`Sources/DesksetCore/Engine/Plugins/WeatherPlugins.swift` (the two measures),
`Sources/DesksetCore/Editor/EditorSchema+Weather.swift` (the editor), `Sources/Deskset/Weather/*` (the app's wiring,
the skin menu's credit, the command-line reports) and `Sources/Deskset/Location/LocationCenter.swift` (Location
Services). Place table: `Data/Places/places.tsv`, made by `scripts/make-places.swift` (see `Data/Places/README.md`).
Tests: `swift run DesksetSelfTest Weather`, `Deskset --self-test Weather`; test skin
`TestSkins/Plugins/Weather/Weather.ini`; fixtures in `TestSkins/Plugins/@Resources/Weather` (a saved MET Norway
response for Oslo, CC BY 4.0, and a small place table).

Sources used: MET Norway's API documentation and terms of service (<https://api.met.no/doc/>,
<https://api.met.no/doc/TermsOfService>, Locationforecast 2.0 and its data model, the weather icon list), the
Creative Commons BY 4.0 licence, GeoNames' export documentation (<https://download.geonames.org/export/dump/>), the
NOAA Global Monitoring Laboratory's published solar calculation equations, Apple's CoreLocation documentation, and the
Rainmeter manual's WebParser, Time, Shape and Image pages for the conventions the plugins follow.

---

## The plugins

### `Plugin=MacWeather` (weather forecasts)
- Windows (Rainmeter): no weather plugin; skins read a weather web site with WebParser
  (<https://docs.rainmeter.net/manual/measures/webparser/>), usually a service that has since shut down.
- Mac (Deskset): forecasts from MET Norway's Locationforecast 2.0 (`complete`), for any place on Earth, 9 days ahead,
  hourly for the first two and a half days. One measure has the place (`Location=`); others follow it with
  `Parent=` and pick what they show with `Type=`, `Hour=` (0–47, the forecast for that hour) or `Day=` (0–9, a daily
  summary in the place's time zone). Numbers are numbers (so `NumOfDecimals`, `Percentual`, `Scale`, bars and
  `IfCondition` work); names and times are strings. Options:

  | Option | Values (default first) | What it does |
  |---|---|---|
  | `Location` | empty · `City[, Region][, Country]` · `lat,lon` · `auto` | The place (see "Places"). Ignored with `Parent`. |
  | `Parent` | a MacWeather measure | Uses its place and its `Units`, unit overrides, `TimeZone`, `FormatLocale`, `Decimals`, `UnavailableText`, `SymbolStyle` (followed up to 8 levels). |
  | `Type` | `Temperature` … (table below) | What the measure shows. |
  | `Hour` | empty · 0–47 | The forecast N hours after the current hour. |
  | `Day` | empty · 0–9 | Today (0), tomorrow (1)…; wins over `Hour`. |
  | `Units` | `Auto` · `Metric` · `Imperial` | Auto follows the Mac: the Temperature setting, then the region (wind in mph for the US and the UK). |
  | `TemperatureUnit`, `WindUnit`, `PrecipitationUnit`, `PressureUnit` | `C`/`F`; `kmh`/`ms`/`mph`/`kn`/`bft`; `mm`/`in`; `hPa`/`inHg`/`mmHg` | One quantity in another unit. |
  | `TimeZone` | `Place` · `Local` · an IANA name · hours from UTC | Day boundaries and times. `Place`: the place's own zone (this Mac's for `auto`). |
  | `Format`, `FormatLocale` | strftime codes, as the Time measure | Times: `%H:%M` or `%#I:%M %p` by the Mac's clock setting; days `%a`. |
  | `Decimals` | empty · 0–3 | Rounds the number itself, half away from zero, never `-0`. |
  | `UnavailableText` | empty | The string while there is no value (e.g. `--`). |
  | `SymbolStyle` | `Fill` · `Outline` | For `Type=Symbol`. |
  | `Hours`, `CurveWidth`, `CurveHeight`, `Smooth` | 24, 200, 40, 1 | For `Type=TemperatureCurve`. |
  | `ColorOf` | `High` · `Low` | For `Type=TemperatureColor` with `Day`. |
  | `FinishAction`, `OnConnectErrorAction`, `OnLocationErrorAction` | bangs | New data (or the place found); a failed request (once per run of failures); a place that cannot be found, Location Services off or no fix. |
  | `!CommandMeasure … "Refresh"` / `"Locate"` | | Refresh: after a failure, try again now (at most once a minute); with fresh data it only reads again. Locate (`auto`): ask for a new fix. |

  Types (N = now, H = with `Hour`, D = with `Day`; without either, daily-only types use today):

  | Type | When | Number | String |
  |---|---|---|---|
  | Temperature, FeelsLike, DewPoint | N H | temperature | — |
  | High, Low | D | temperature | — |
  | Condition, Symbol, SymbolCode | N H D | MET's legacy number (1 clear … 50 heavy snow) | "Partly cloudy" / SF Symbol name / MET's code |
  | IsDaylight | N H | 1 day, 0 night, 2 polar twilight | — |
  | Humidity, CloudCover, Fog | N H | % | — |
  | Pressure | N H | pressure | — |
  | UVIndex, WindSpeed (`Wind`), WindGust | N H D (day: the highest) | value | — |
  | WindDirection, WindCardinal | N H | degrees the wind comes **from** | "NW" |
  | Beaufort | N H D | 0–12 | "Gentle breeze" |
  | Precipitation | N H (next hour) D (day's total) | amount | — |
  | PrecipitationChance, ThunderChance | N H D (day: the highest) | % | — |
  | TemperatureColor | N H D | temperature | "R,G,B" (an original palette from blue to red) |
  | TemperatureCurve | N | 0 | a Shape `Path` of the next hours (`Curve=[MeasureCurve]`) |
  | Time | N H D | the hour's or day's time (Time-measure value) | `Format` |
  | Sunrise, Sunset, SolarNoon, DayLength, DaylightProgress | N D | times / seconds / 0–1 | `Format`, "h:mm" |
  | Place, PlaceDetail, Country, CountryCode | — | 0 | "Oslo", "Oslo, Oslo, Norway", "Norway", "NO" |
  | Latitude, Longitude | — | the rounded coordinate used | — |
  | TimeZone | — | hours from UTC now | IANA name |
  | UpdatedAt, ForecastTime | — | when the data was last fetched or confirmed / when MET made the forecast | `Format` |
  | Status, StatusSymbol | — | 0–13 (see "States") | "Updated 12:05" / SF Symbol name |
  | Attribution, AttributionShort, AttributionURL, LicenseURL | — | 0 | "Based on data from MET Norway", "Data: MET Norway", the links |
  | TemperatureUnit, WindUnit, PrecipitationUnit, PressureUnit | — | 0 | "°C", "km/h", "mm", "hPa" |

  Automatic MinValue / MaxValue (the skin's own win): temperatures over the next 24 hours; High and Low over the week
  (the same for every day, so range bars line up); percentages 0–100; UV 0–11; wind 0 to the strongest of the next
  24 hours; pressure 950–1050 hPa; directions 0–360; the curve over its hours.
- Why: Deskset extension. The weather services Windows skins scraped (weather.com's XML feed, Yahoo) are gone, and
  MET Norway's forecasts are free for any use, need no key or account and cover the whole world.
- Skin impact: skins written for Deskset get weather without scraping; Windows skins cannot use these measures.
- Status: Deskset extension

### How "now", hours and days are worked out (judgment calls)
- Windows (Rainmeter): n/a.
- Mac (Deskset): "now" is the latest forecast step at or before the current time (a step up to an hour ahead is used
  before the first one). `Hour=N` is the step exactly N hours later that has a one-hour forecast (0–47 always exists
  in fresh data). A day runs from local midnight to local midnight in the display time zone (23- and 25-hour days at
  daylight saving changes): its high and low are the extremes of the hourly temperatures in it plus the six-hour
  extremes of the later part of the forecast, today's also the hours already gone (kept from earlier responses);
  rain is the sum of the forecast periods, shared out by how much of each falls in the day; chances, wind, gusts
  and UV are the highest; the icon is that of the six-hour period nearest to local noon, always shown as by day. A
  day counts when at least 12 of its hours are covered (today: any). The weather condition is MET's own symbol, which
  already tells day from night.
- Why: the forecast is a list of hourly and six-hourly steps; skins want "now", hours and days.
- Skin impact: daily values may differ slightly from yr.no's own summaries.
- Status: Deskset extension

### Places (`Location=`)
- Windows (Rainmeter): n/a (each weather site has its own location codes).
- Mac (Deskset): `Location` is a place name — `Oslo`, `Oslo, NO`, `Springfield, IL`, `Springfield, Illinois, US`,
  `北京`, `zurich` (case, accents and width ignored; CJK names also without a trailing 市 / 县 / 区) — or
  `latitude,longitude` (`59.91,10.75`, `59.91 10.75`, `59.91N 10.75E`; a point for decimals, so `59,91, 10,75` is
  refused with a note), or `auto` (this Mac's location, next entry). Names are looked up **on the Mac** in a table of
  the world's towns of 15,000 people or more (GeoNames, bundled): the most populous match wins, a country or region
  after a comma narrows it, and a prefix of three letters or more finds a town when nothing matches exactly. Smaller
  places: use coordinates. The name shown (`Type=Place`) is the table's, or the user's own spelling when an
  alternate name matched ("北京"); coordinates show the nearest town within 50 km. Every coordinate is **rounded to
  two decimals** (about 1 km) before it is used or sent; places that round to the same point share one forecast.
- Why: no online geocoder fits (terms that forbid commercial use or storing results, or wrong answers for foreign
  names from some regions), and an offline table keeps place names private.
- Skin impact: small villages need coordinates; the table is updated with Deskset.
- Status: Deskset extension

### `Location=auto` and Location Services
- Windows (Rainmeter): n/a.
- Mac (Deskset): `auto` (also `current`, `here`) uses this Mac's approximate location. macOS asks for Location
  Services once, the first time a skin in a skin window uses it (never for previews, `--render` or the Manage
  window); the accuracy is reduced (about 5 km) and the fix is rounded to two decimals before anything keeps it. It is
  kept in memory for an hour, never written to disk and never logged, and its forecast is not cached on disk. The
  place name comes from the offline table (no reverse geocoding). When Location Services are off, the skin gets a
  compatibility note (removed once they are allowed) and `Status` 5; without a fix (Wi-Fi off) `Status` 6 and new
  tries after 1, 5, 15 and then every 30 minutes. The same permission serves WiFiStatus's network names.
- Why: privacy; only the rounded coordinate is needed.
- Skin impact: a one-time prompt; skins that should work without it use a place name.
- Status: Deskset extension

### Requests, cache and MET Norway's terms
- Windows (Rainmeter): n/a.
- Mac (Deskset): one HTTPS request per place (`…/locationforecast/2.0/complete?lat=…&lon=…`, two decimals, no
  altitude), shared by every measure of every skin, identified as `Deskset/<version> (+https://github.com/jokyme/Deskset)`.
  The next request waits for the response's `Expires` time (corrected for the server's clock) and at least 30 minutes,
  plus a random 1–10 minutes, and asks "if modified since" with the previous `Last-Modified`. Failures back off: 429
  from 10 minutes doubling to 2 hours (or `Retry-After`), server errors from 5 minutes to an hour, no network from 1
  minute to 15; 400 / 403 stop until Refresh, a relaunch or a day; 404 / 422 ("no forecast here") retry after a day.
  Only skins in skin windows request anything; a place nothing has read for 30 minutes (hidden, paused or disabled
  measures) sleeps, and nothing is requested while the Mac sleeps (after waking, a random 10–60 s first). At most 8
  places are live at once (the 9th shows `Status` 13). Forecasts of places written in a skin are cached in
  `~/Library/Caches/Deskset/Weather` (at most 32 files, 7 days) so they show at once after a relaunch. Values keep
  moving along the stored forecast when a request fails; data older than 48 hours is no longer shown.
- Why: MET Norway's terms (identify the app, respect `Expires`, conditional requests, spread the load, no traffic from
  idle apps) and a shared free service.
- Skin impact: data is at most about 40 minutes older than MET's latest; `Refresh` cannot force requests more often.
- Status: Deskset extension

### States (`Type=Status`)
- Windows (Rainmeter): n/a.
- Mac (Deskset): 0 Ready ("Updated 12:05"), 1 Loading, 2 Stale (data shown, the last try failed or it is 2 hours past
  its expiry: "Offline · updated 09:30"), 3 NoLocation ("Set a location"), 4 PlaceNotFound, 5 LocationDenied,
  6 LocationUnavailable, 7 NotCovered, 8 Refused, 9 RateLimited, 10 Offline, 11 TurnedOff (`WeatherEnabled` off),
  12 Preview (not a skin window: `--render`, the Manage window, thumbnails), 13 TooManyPlaces. Without data weather
  values are unavailable (number 0, the string `UnavailableText`; `Symbol` and `StatusSymbol` then give an empty name,
  so `ImageName=sf:%1` draws nothing). Sun values need only the place. Place, location and refusal problems also add
  a compatibility note.
- Why: skins need to tell "no data yet" from "no data at all".
- Skin impact: show `Type=Status` (or hide parts with `IfCondition`).
- Status: Deskset extension

### Credit (CC BY 4.0)
- Windows (Rainmeter): n/a.
- Mac (Deskset): MET Norway's data is licensed under CC BY 4.0. `Type=Attribution` ("Based on data from MET Norway"),
  `AttributionShort`, `AttributionURL` and `LicenseURL` let a skin show the credit; in addition the right-click menu of
  **every** skin with a MacWeather measure has "Weather: Based on data from MET Norway ↗" (opens api.met.no) and the
  time of the data, so third-party skins credit the source too. The About window and the bundled notices name MET
  Norway and GeoNames.
- Why: the licence asks for credit and a note that the data was changed (daily values and units are derived).
- Skin impact: please show `Type=Attribution` somewhere in weather skins.
- Status: Deskset extension

### Privacy and turning weather off
- Windows (Rainmeter): n/a.
- Mac (Deskset): MET Norway receives the Mac's IP address and the rounded coordinate of each place (nothing else:
  no place name, no identifier). Nothing is requested until a skin in a skin window has a place. `defaults write
  app.deskset.Deskset WeatherEnabled -bool NO` turns all requests off (skins show "Weather is turned off", `Status`
  11); `defaults delete app.deskset.Deskset WeatherEnabled` turns them on again. The log says "Weather: fetched (200)"
  and never a coordinate (`defaults write app.deskset.Deskset WeatherDebug -bool YES` adds the rounded coordinates and
  timings, for debugging).
- Why: forecasts need a place; the rounding and the offline place table keep the rest on the Mac.
- Skin impact: none.
- Status: Deskset extension

### `Plugin=MacSun` (sun and moon, offline)
- Windows (Rainmeter): n/a.
- Mac (Deskset): sun and moon for a place, worked out on the Mac with the NOAA solar equations (within a minute below
  65° of latitude, a few minutes beyond) and the mean lunar month (within about a day); never the network. Options:
  `Location` (as MacWeather; `auto` shares its fix), `Parent` (another MacSun), `Type`, `Day` (−1…30), `Format`,
  `FormatLocale`, `TimeZone`, `NoEventText` (default `--:--`, when the sun does not rise or set), `UnavailableText`.
  Types: `Sunrise`, `Sunset`, `SolarNoon`, `CivilDawn`, `CivilDusk`, `NauticalDawn`, `NauticalDusk`,
  `AstronomicalDawn`, `AstronomicalDusk`, `GoldenHourMorningEnd`, `GoldenHourEveningStart` (times: a Time-measure
  value and `Format`), `DayLength`, `DaylightProgress` (0 before sunrise, 1 after sunset; midnight sun: the share of
  the day gone), `SunElevation`, `SunAzimuth`, `IsDaylight`, `SunState` (0, 1 midnight sun, 2 polar night),
  `MoonPhase` (0 new, 0.5 full), `MoonIllumination`, `MoonPhaseName`, `MoonSymbol` (an SF Symbol name), `Place`,
  `TimeZone`. MacWeather's sun types use the same code for the forecast's place. It works in `--render` and previews.
- Why: clock skins want sunrise and sunset without a network or an account.
- Skin impact: none for Windows skins.
- Status: Deskset extension

### Weather icons (SF Symbols)
- Windows (Rainmeter): skins ship icon images named after their weather service's codes.
- Mac (Deskset): `Type=Symbol` gives an SF Symbol name for MET's 83 weather codes (day and night forms; names that
  exist on macOS 13), drawn with `ImageName=sf:%1` in an Image meter (the "SF Symbols as images" extension in
  `engine.md`; `MacSymbolRendering=Multicolor` gives the colored forms). `SymbolStyle=Outline` drops `.fill`.
  `Type=SymbolCode` gives MET's code (`partlycloudy_day`) for skins with their own images. Sleet and snow showers
  share one symbol (there is no sun-and-snow symbol on macOS 13).
- Why: no icon files to ship; the symbols match the system.
- Skin impact: none.
- Status: Deskset extension

### Many values from one measure (`[&Measure:Now(…)]`)
- Windows (Rainmeter): section variable functions exist for Lua and some plugins
  (<https://docs.rainmeter.net/manual/variables/section-variables/>).
- Mac (Deskset): a MacWeather measure answers `[&MeasureWeather:Now(Humidity, 0)]`,
  `[&MeasureWeather:Hour(3, Temperature, 0)]` and `[&MeasureWeather:Day(1, High, 0)]` (index, Type, optional
  decimals): the string, or the number with those decimals (meters need `DynamicVariables=1`).
- Why: a forecast strip would otherwise need dozens of child measures.
- Skin impact: none.
- Status: Deskset extension

### Previews, `--render` and demo data
- Windows (Rainmeter): n/a.
- Mac (Deskset): outside skin windows weather measures never request anything and show `Status` 12 (Preview); sun
  values and place names still work. `DESKSET_WEATHER_DEMO=1 Deskset --render Skin.ini …` draws a made-up,
  deterministic forecast instead (`DESKSET_WEATHER_DEMO_NOW=2026-09-26T12:00:00Z` fixes its clock), for screenshots.
- Why: repeatable images without network traffic.
- Skin impact: none (developer tool).
- Status: Deskset extension

### Windows weather skins (weather.com, Yahoo and other scraped services)
- Windows (Rainmeter): such skins show nothing either: the XML services they read were shut down.
- Mac (Deskset): they load, their WebParser measures fail as on Windows, and their weather parts stay empty. Deskset
  does not imitate those services' addresses. Rewriting the weather part with MacWeather (a parent with the place,
  children with `Parent=`, `ImageName=sf:%1` or `Type=SymbolCode` for the icons) brings them back.
- Why: the services no longer exist; faking them would mean pretending to be someone else's service.
- Skin impact: weather parts of old skins stay empty until rewritten.
- Status: not supported
