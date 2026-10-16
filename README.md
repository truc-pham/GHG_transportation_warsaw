# Bus emissions on Aleje Jerozolimskie, Warsaw

Street-level estimate of bus CO2, NOx and PM10 on Aleje Jerozolimskie, every street connected to it, and the whole Warsaw bus network, built from open GTFS timetable data in R.

This repository is the public-transport part of a research internship at the [Institute for Sustainable Development Foundation](https://www.pine.org.pl/english/) (Warsaw, March–May 2026), carried out within the MSc in Sustainable Development at the University of Warsaw. The project write-up is on [my website](https://truc-pham.github.io/project/carbon-streets/).

![Bus CO2, NOx and PM10 on Aleje Jerozolimskie and its cross streets](outputs/figures/map_pollutants_zone.png)

## Question

How much do buses emit along Aleje Jerozolimskie and on the streets that cross it on a typical weekday, which routes and vehicle types contribute most, and how much of the service is already electric?

## Key results (weekday, 18 March 2026)

**Buses travelling along Al. Jerozolimskie**

| Measure | Value |
| --- | --- |
| Routes / trips per day | 38 / 3,505 |
| Bus-km per day | 6,672 |
| Share of bus-km run by electric buses | 36.9% |
| CO2 (exhaust) | 5.4 t per day |
| NOx (exhaust) | 44 kg per day |
| PM10, exhaust | 0.94 kg per day |
| PM10, brake, tyre and road wear | 0.65 kg per day |
| PM10, total | 1.59 kg per day |

**Corridor zone: Al. Jerozolimskie plus every cross and side street within 250 m**

| Part of the zone | Bus-km per day | CO2 (t/day) | NOx (kg/day) | PM10 (kg/day) |
| --- | --- | --- | --- | --- |
| Al. Jerozolimskie | 6,700 | 5.5 | 44.6 | 1.6 |
| Cross and side streets | 8,227 | 8.7 | 71.0 | 2.3 |
| Whole zone | 14,927 | 14.2 | 115.6 | 3.9 |

- Articulated (18 m) diesel buses drive about half of the corridor bus-km and emit over 80% of its CO2.
- Electric routes 127, 158 and 128 are among the busiest on the corridor. If the same bus-km were run by diesel buses of the same size, corridor CO2 would be about 3.4 t per day higher, so electrification already avoids roughly 38% of it.
- **Non-exhaust particles matter.** Brake, tyre and road wear make up 41% of bus PM10 on the corridor, and electric buses still produce them.
- **Together, the cross streets carry more bus-km than the corridor itself** inside the zone (8,227 vs 6,700); the busiest are al. Prymasa Tysiąclecia, Łopuszańska, Grójecka, Grzymały-Sokołowskiego and Emilii Plater.
- Service peaks at about 230 buses per hour between 07:00 and 08:00.

**Three levels: the street, its connected streets, and the whole city**

![Bus emissions on every bus street in Warsaw](outputs/figures/map_warsaw_bus_network.png)

| Level | Bus-km per day | CO2 (t/day) | NOx (kg/day) | PM10 (kg/day) | Share of city bus CO2 |
| --- | --- | --- | --- | --- | --- |
| Al. Jerozolimskie | 6,700 | 5.5 | 45 | 1.6 | 1.6% |
| 26 connected streets, full length | 14,381 | 15.0 | 122 | 4.0 | 4.3% |
| Rest of the bus network | 239,201 | 265.5 | 2,166 | 69.1 | 76.5% |
| Long links across several streets (express sections, depot runs) | 54,908 | 61.2 | 499 | 15.9 | 17.6% |
| **Whole Warsaw bus network** | **315,189** | **347.1** | **2,832** | **90.6** | 100% |

- Al. Jerozolimskie ranks **5th of all Warsaw bus streets** for bus CO2 (`warsaw_bus_emissions_by_street.csv`).
- Among its connected streets, al. Prymasa Tysiąclecia (17th in Warsaw) and Łopuszańska (23rd) carry the most bus emissions (`co2_connected_streets.png`, `map_connected_streets.png`).
- Streets without bus service, including most small residential streets, have no bus emissions. Their traffic is cars and vans, which timetable data cannot capture.

Full tables are in [`outputs/tables`](outputs/tables), including `whole_route_emissions.csv`: the full daily footprint of all 50 routes that use or cross the corridor. This is reported separately because most of it occurs far from the street.

## Data

| Input | Source |
| --- | --- |
| GTFS feed for Warsaw public transport, published 15 March 2026 (`data/raw/`) | [mkuran.pl/gtfs](https://mkuran.pl/gtfs/) (Mikołaj Kuranowski), based on ZTM Warszawa open data |
| Fuel use by vehicle class (`params/fleet_classes.csv`) | Assumed values, flagged in the file (see Limitations) |
| Emission factors per kg of diesel (`params/emission_factors.csv`) | [EMEP/EEA air pollutant emission inventory guidebook 2023](https://www.eea.europa.eu/publications/emep-eea-guidebook-2023), chapter 1.A.3.b.i-iv Road transport (2024 update), Tables 3-6 and 3-12 |

## Method

1. **Service day.** Select all trips that run on Wednesday 18 March 2026, using `calendar_dates.txt`.
2. **Buses only.** Keep GTFS `route_type = 3`. Trams, metro and rail also use the corridor but are electric and excluded.
3. **Along the corridor.** A trip travels along the corridor when it serves at least two consecutive stops whose `street_name` is *Al. Jerozolimskie* (inside Warsaw). One stop recorded under a cross-street name is allowed inside a run.
4. **Cross streets.** All bus stop-to-stop links within 250 m of the corridor are cut out of the real bus shapes and clipped to that zone. Each link is named after the street of its stops. Crossing routes count only for the stretch inside the zone, not for their whole length.
5. **Distance.** Bus-km = the distance travelled between stops (`shape_dist_traveled`), summed over all trips of the day.
6. **Vehicle class.** Each trip's `fleet_type` gives its size and powertrain (midi, 12 m, 18 m diesel; 12 m, 18 m electric).
7. **Emission rates per bus-km** (`outputs/tables/emission_rates_g_per_bus_km.csv`):
    - CO2, NOx and exhaust PM10 = fuel use (L/100 km) / 100 × 0.835 kg/L × factor per kg diesel. They are zero for electric buses.
    - Brake, tyre and road-wear PM10 = 0.059 + 0.038 g per bus-km for every bus, including electric ones.
8. **Whole network and connected streets.** Every stop-to-stop bus link in Warsaw is mapped. A link belongs to the street both its stops are on; a short turn between two streets (≤ 0.8 km) is split between them, and turns that touch the corridor go to the cross street; longer links that change street are kept in the city total as their own group. *Connected streets* are the streets with a bus stop within 250 m of the corridor, counted over their whole connected stretch (namesake streets elsewhere in Warsaw are excluded).
9. **Mapping.** Results are aggregated to stop-to-stop links and drawn along the bus shapes, as emissions per km of street per day.

## How to run

Requires R (≥ 4.1) and the packages `data.table`, `sf`, `ggplot2` and `patchwork`.

```r
install.packages(c("data.table", "sf", "ggplot2", "patchwork"))
# open GHG_transportation_warsaw.Rproj, then:
source("R/bus_corridor_emissions.R")
```

The script runs in under a minute and writes all tables and figures to `outputs/`. To study another street, day or zone width, change `corridor`, `service_date` or `zone_m` in the script.

## Repository structure

```
R/bus_corridor_emissions.R     full pipeline
params/fleet_classes.csv       fuel use by vehicle class
params/emission_factors.csv    emission factors with sources
data/raw/                      GTFS snapshot used for the results
outputs/tables/                CSV results; zone and city-wide link geometry (GeoPackage, opens in QGIS)
outputs/figures/               map and charts
```

## Limitations

- **Fuel use per vehicle class is assumed** (28, 40 and 52 L/100 km for midi, 12 m and 18 m diesel buses). Replace these with operator data from MZA or COPERT Tier 2 values to refine the estimate.
- **Tier 1 NOx and PM factors** are fleet averages across Euro standards. They overestimate emissions from a modern Euro VI fleet.
- **All non-electric buses are treated as diesel.** Hybrid and CNG buses in the Warsaw fleet are not identified in the feed.
- **Scheduled, not observed, service.** Congestion, idling, cancellations and stop-and-go driving are not modelled.
- **Non-exhaust PM10 uses one factor for all buses.** Electric buses brake partly by regeneration (less brake wear) but are heavier (more tyre and road wear); the guidebook's Tier 1 factor does not separate these.
- **Buses only, direct emissions only.** Cars, trucks and trams on the same streets, and electricity generation for electric buses, are outside the scope.
- **Zone width (250 m) is a choice.** It captures the approaches to each junction; `zone_m` can be changed.

## Licence

Code: [MIT](LICENSE). Timetable data are provided by Zarząd Transportu Miejskiego w Warszawie and compiled into GTFS by Mikołaj Kuranowski; bus shapes are based on © OpenStreetMap contributors (ODbL). See `attributions.txt` inside the feed.

## Author

**Truc Pham** · [truc-pham.github.io](https://truc-pham.github.io) · [ORCID 0009-0004-1892-492X](https://orcid.org/0009-0004-1892-492X)
