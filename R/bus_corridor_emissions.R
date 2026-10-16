# =============================================================================
# Bus emissions on an urban corridor from GTFS timetable data
# Case study: Aleje Jerozolimskie, Warsaw (one weekday of scheduled service)
#
# Author: Truc Pham
#
# Method (Tier 1, distance-based):
#   1. Keep bus trips (GTFS route_type 3) that run on the chosen service date.
#   2. A trip travels along the corridor when it serves >= 2 consecutive stops
#      whose `street_name` is the corridor street.
#   3. Bus-km = distance between stops (`shape_dist_traveled`, in km).
#   4. Emissions per bus-km depend on the vehicle class (`fleet_type`):
#        CO2, NOx, PM10 exhaust = fuel use x factor per kg diesel (zero if electric)
#        PM10 brake, tyre and road wear = factor per bus-km (all buses)
#   5. Zone analysis: every bus link within `zone_m` metres of the corridor,
#      including cross and side streets, clipped to the zone.
#   6. Whole-route footprint of every route that uses or crosses the corridor.
#   7. Network: every bus link in Warsaw, the full length of every street that
#      crosses or joins the corridor, and city-wide totals for context.
#
# Inputs : data/raw/warsaw_gtfs_*.zip   (GTFS feed, Mikolaj Kuranowski / mkuran.pl)
#          params/fleet_classes.csv      (fuel use by vehicle class)
#          params/emission_factors.csv   (factors per kg diesel or per bus-km)
# Outputs: outputs/tables/*.csv, outputs/figures/*.png
#
# Run from the project root (open GHG_transportation_warsaw.Rproj, then
# source("R/bus_corridor_emissions.R")).
# =============================================================================

suppressPackageStartupMessages({
  library(data.table)
  library(sf)
  library(ggplot2)
})

# --- 1. Settings --------------------------------------------------------------
gtfs_zip      <- "data/raw/warsaw_gtfs_2026-03-15.zip"
service_date  <- "20260318"            # a regular weekday (Wednesday) in the feed
corridor      <- "Al. Jerozolimskie"   # value of stops.txt `street_name`
corridor_town <- "Warszawa"            # keep the part of the street inside Warsaw
max_gap       <- 1L   # allow 1 stop recorded under a cross-street name inside a run
diesel_kg_l   <- 0.835                 # diesel density, kg per litre

dir.create("outputs/tables",  recursive = TRUE, showWarnings = FALSE)
dir.create("outputs/figures", recursive = TRUE, showWarnings = FALSE)

# --- 2. Read GTFS --------------------------------------------------------------
gtfs_dir <- file.path(tempdir(), "gtfs")
unzip(gtfs_zip, exdir = gtfs_dir, overwrite = TRUE)
read_gtfs_table <- function(name, ...) {
  fread(file.path(gtfs_dir, paste0(name, ".txt")), encoding = "UTF-8", ...)
}

routes <- read_gtfs_table("routes", colClasses = "character")
trips  <- read_gtfs_table("trips",  colClasses = "character",
                          select = c("trip_id", "route_id", "service_id",
                                     "shape_id", "direction_id", "fleet_type"))
cal    <- read_gtfs_table("calendar_dates", colClasses = "character")
stops  <- read_gtfs_table("stops",  colClasses = list(character = "stop_id"),
                          select = c("stop_id", "stop_name", "stop_lat",
                                     "stop_lon", "street_name", "town_name"))

# Services running on the chosen date (this feed has only calendar_dates.txt)
services <- cal[date == service_date & exception_type == "1", service_id]
if (length(services) == 0) stop("No service found on ", service_date)

bus_routes <- routes[route_type == "3", .(route_id, route = route_short_name)]
bus_trips  <- trips[service_id %in% services][bus_routes, on = "route_id", nomatch = 0]
message(sprintf("%s bus trips scheduled on %s", format(nrow(bus_trips), big.mark = ","),
                service_date))

st <- read_gtfs_table("stop_times",
                      select = c("trip_id", "stop_sequence", "stop_id",
                                 "departure_time", "shape_dist_traveled"),
                      colClasses = list(character = c("trip_id", "stop_id",
                                                      "departure_time")))
st <- st[trip_id %in% bus_trips$trip_id]
setorder(st, trip_id, stop_sequence)
st[, pos := seq_len(.N), by = trip_id]

# --- 3. Find the corridor runs of each trip ------------------------------------
corridor_stop_ids <- stops[street_name == corridor & town_name == corridor_town, stop_id]
st[, on_corridor := stop_id %in% corridor_stop_ids]

runs <- st[on_corridor == TRUE]
runs[, run := cumsum(c(1L, diff(pos) > max_gap + 1L)), by = trip_id]
runs <- runs[, .(first_pos = min(pos), last_pos = max(pos), n_stops = .N,
                 enter_time = departure_time[1]), by = .(trip_id, run)]
runs <- runs[n_stops >= 2]   # a single stop = the trip only crosses the street

# Stop-to-stop links inside each run (gap stops included, so no distance is lost)
links <- st[runs, on = .(trip_id, pos >= first_pos, pos <= last_pos),
            .(trip_id, run = i.run, pos = x.pos, stop_id = x.stop_id,
              dist_km = x.shape_dist_traveled, enter_time = i.enter_time)]
setorder(links, trip_id, run, pos)
links[, `:=`(to_stop_id = shift(stop_id, -1L),
             link_km    = shift(dist_km, -1L) - dist_km), by = .(trip_id, run)]
links <- links[!is.na(to_stop_id)]
stopifnot(all(links$link_km >= 0))


# --- 4. Emission rates per bus-km by vehicle class -------------------------------
fleet <- fread("params/fleet_classes.csv")
ef    <- fread("params/emission_factors.csv")
ef_v  <- setNames(ef$value, ef$pollutant)

unknown <- setdiff(unique(bus_trips$fleet_type), fleet$fleet_type)
if (length(unknown) > 0) {
  warning("Fleet types without parameters (dropped): ", paste(unknown, collapse = ", "))
}

# g per bus-km for each class
rates <- fleet[, .(fleet_type, class_label, powertrain,
                   fuel_kg_km = fuel_l_per_100km / 100 * diesel_kg_l)]
rates[, `:=`(CO2  = fuel_kg_km * ef_v[["CO2"]],
             NOx  = fuel_kg_km * ef_v[["NOx"]],
             PM10_exhaust    = fuel_kg_km * ef_v[["PM10_exhaust"]],
             PM10_nonexhaust = ef_v[["PM10_tyre_brake"]] + ef_v[["PM10_road_wear"]])]
rates[, PM10 := PM10_exhaust + PM10_nonexhaust]
pollutants <- c("CO2", "NOx", "PM10_exhaust", "PM10_nonexhaust", "PM10")
fwrite(rates[, c("fleet_type", "class_label", pollutants), with = FALSE][
  , (pollutants) := lapply(.SD, round, 4), .SDcols = pollutants],
  "outputs/tables/emission_rates_g_per_bus_km.csv")

trip_info <- bus_trips[, .(trip_id, route, shape_id, fleet_type)][
  rates[, c("fleet_type", "class_label", "powertrain", pollutants), with = FALSE],
  on = "fleet_type", nomatch = 0]

add_emissions <- function(dt) {   # dt has trip_id and link_km; adds g per pollutant
  dt <- dt[trip_info, on = "trip_id", nomatch = 0]
  for (p in pollutants) set(dt, j = paste0(p, "_g"), value = dt$link_km * dt[[p]])
  dt[, (pollutants) := NULL]
  dt
}
links <- add_emissions(links)

# --- 5. Corridor tables (buses that travel along the street) -----------------------
trip_summary <- links[, .(route = route[1], class_label = class_label[1],
                          powertrain = powertrain[1], enter_time = enter_time[1],
                          corridor_km = sum(link_km), CO2_g = sum(CO2_g),
                          NOx_g = sum(NOx_g), PM10_exhaust_g = sum(PM10_exhaust_g),
                          PM10_nonexhaust_g = sum(PM10_nonexhaust_g), PM10_g = sum(PM10_g)),
                      by = trip_id]

summarise_emissions <- function(dt) {
  dt[, .(trips_per_day   = .N,
         bus_km_per_day  = round(sum(corridor_km), 1),
         CO2_kg_per_day  = round(sum(CO2_g) / 1e3, 1),
         NOx_kg_per_day  = round(sum(NOx_g) / 1e3, 2),
         PM10_exhaust_g_per_day    = round(sum(PM10_exhaust_g), 1),
         PM10_nonexhaust_g_per_day = round(sum(PM10_nonexhaust_g), 1),
         PM10_g_per_day  = round(sum(PM10_g), 1))]
}
by_route <- trip_summary[, c(.(share_electric = round(mean(powertrain == "electric"), 2)),
                             summarise_emissions(.SD)), by = route][order(-CO2_kg_per_day)]
by_class <- trip_summary[, summarise_emissions(.SD), by = .(class_label, powertrain)][
  order(-bus_km_per_day)]

trip_summary[, hour := as.integer(substr(enter_time, 1, 2))]
by_hour <- trip_summary[, .(buses = .N, CO2_kg = round(sum(CO2_g) / 1e3, 2),
                            NOx_g = round(sum(NOx_g)), PM10_g = round(sum(PM10_g), 1)),
                        by = hour][order(hour)]

totals <- cbind(data.table(service_date, corridor, routes = uniqueN(trip_summary$route),
                           electric_share_of_bus_km = round(
                             trip_summary[powertrain == "electric", sum(corridor_km)] /
                               trip_summary[, sum(corridor_km)], 3)),
                summarise_emissions(trip_summary))

fwrite(totals,   "outputs/tables/corridor_totals.csv")
fwrite(by_route, "outputs/tables/emissions_by_route.csv")
fwrite(by_class, "outputs/tables/emissions_by_vehicle_class.csv")
fwrite(by_hour,  "outputs/tables/buses_by_hour.csv")
print(totals)

# --- 6. All bus links of the day (needed for cross streets and whole routes) -------
all_links <- st[, .(stop_id, to_stop_id = shift(stop_id, -1L), pos,
                    dist_km = shape_dist_traveled,
                    link_km = shift(shape_dist_traveled, -1L) - shape_dist_traveled),
                by = trip_id][!is.na(to_stop_id)]
all_links <- add_emissions(all_links)

# Whole-route footprint of every route that uses or crosses the corridor
touching_routes <- unique(bus_trips[trip_id %in% st[on_corridor == TRUE, trip_id], route])
whole_routes <- all_links[route %in% touching_routes,
                          .(trips_per_day   = uniqueN(trip_id),
                            route_km_per_day = round(sum(link_km), 0),
                            CO2_t_per_day   = round(sum(CO2_g) / 1e6, 2),
                            NOx_kg_per_day  = round(sum(NOx_g) / 1e3, 1),
                            PM10_kg_per_day = round(sum(PM10_g) / 1e3, 2)), by = route]
whole_routes[, travels_along_corridor := route %in% trip_summary$route]
setorder(whole_routes, -CO2_t_per_day)

# --- 7. Geometry: cut each stop-to-stop link out of its bus shape ------------------
shapes <- read_gtfs_table("shapes", colClasses = list(character = "shape_id"))
setkey(shapes, shape_id)

cut_shape <- function(id, d0, d1) {
  pts <- shapes[.(id)][shape_dist_traveled >= d0 - 1e-6 & shape_dist_traveled <= d1 + 1e-6]
  if (nrow(pts) < 2) return(NULL)
  st_linestring(as.matrix(pts[order(shape_pt_sequence), .(shape_pt_lon, shape_pt_lat)]))
}
xy <- stops[, .(stop_id, stop_lon, stop_lat)]
links_to_sf <- function(flows) {   # flows: one row per stop pair with shape_id, d0, d1
  geoms <- mapply(cut_shape, flows$shape_id, flows$d0, flows$d1, SIMPLIFY = FALSE)
  for (i in which(vapply(geoms, is.null, logical(1)))) {   # straight line fallback
    a <- xy[stop_id == flows$stop_id[i]]; b <- xy[stop_id == flows$to_stop_id[i]]
    geoms[[i]] <- st_linestring(rbind(c(a$stop_lon, a$stop_lat), c(b$stop_lon, b$stop_lat)))
  }
  st_sf(flows, geometry = st_sfc(geoms, crs = 4326))
}
sum_by_pair <- function(dt) {
  dt[, .(buses = .N, link_km = median(link_km), shape_id = shape_id[1],
         d0 = dist_km[1], d1 = dist_km[1] + link_km[1],
         CO2_g = sum(CO2_g), NOx_g = sum(NOx_g), PM10_exhaust_g = sum(PM10_exhaust_g),
         PM10_nonexhaust_g = sum(PM10_nonexhaust_g), PM10_g = sum(PM10_g)),
     by = .(stop_id, to_stop_id)]
}

corridor_sf <- links_to_sf(sum_by_pair(links))
corridor_pairs <- paste(corridor_sf$stop_id, corridor_sf$to_stop_id)

# Zone = everything within `zone_m` metres of the corridor (EPSG:2180, Poland CS92)
zone_m <- 250
zone   <- st_union(st_transform(corridor_sf, 2180)) |> st_buffer(zone_m)

stops_2180 <- st_transform(st_as_sf(stops, coords = c("stop_lon", "stop_lat"), crs = 4326), 2180)
near_ids   <- stops_2180$stop_id[lengths(st_intersects(stops_2180,
                                                       st_buffer(zone, 1500))) > 0]
cand <- sum_by_pair(all_links[stop_id %in% near_ids | to_stop_id %in% near_ids])
cand_sf <- st_transform(links_to_sf(cand), 2180)
cand_sf <- cand_sf[lengths(st_intersects(cand_sf, zone)) > 0, ]

full_len <- as.numeric(st_length(cand_sf))
zone_sf  <- suppressWarnings(st_intersection(cand_sf, zone))
zone_sf  <- zone_sf[!st_is_empty(zone_sf), ]
frac     <- pmin(1, as.numeric(st_length(zone_sf)) /
                   full_len[match(paste(zone_sf$stop_id, zone_sf$to_stop_id),
                                  paste(cand_sf$stop_id, cand_sf$to_stop_id))])
for (v in c("CO2_g", "NOx_g", "PM10_exhaust_g", "PM10_nonexhaust_g", "PM10_g")) {
  zone_sf[[v]] <- zone_sf[[v]] * frac
}
zone_sf$zone_km    <- zone_sf$link_km * frac
zone_sf$bus_km     <- zone_sf$zone_km * zone_sf$buses
zone_sf$on_corridor <- paste(zone_sf$stop_id, zone_sf$to_stop_id) %in% corridor_pairs

# Name each link by the street it runs on inside the zone: the corridor for links
# along it; otherwise the street of an end stop that lies inside the zone and is not
# on the corridor (a long express link is named after the street near the corridor).
street_of <- setNames(stops$street_name, stops$stop_id)
street_of[is.na(street_of) | street_of == ""] <- "Unnamed"
zone_stop_ids <- stops_2180$stop_id[lengths(st_intersects(stops_2180, zone)) > 0]
s_from <- street_of[zone_sf$stop_id]; s_to <- street_of[zone_sf$to_stop_id]
from_in <- zone_sf$stop_id %in% zone_stop_ids & s_from != corridor
to_in   <- zone_sf$to_stop_id %in% zone_stop_ids & s_to != corridor
zone_sf$street <- ifelse(zone_sf$on_corridor, corridor,
                  ifelse(from_in, s_from,
                  ifelse(to_in, s_to,
                  ifelse(s_to != corridor, s_to, s_from))))

zone_dt <- as.data.table(st_drop_geometry(zone_sf))
by_street <- zone_dt[, .(bus_km_per_day = round(sum(bus_km), 1),
                         CO2_kg_per_day = round(sum(CO2_g) / 1e3, 1),
                         NOx_kg_per_day = round(sum(NOx_g) / 1e3, 2),
                         PM10_g_per_day = round(sum(PM10_g), 1)),
                     by = .(street, on_corridor)][order(-CO2_kg_per_day)]
zone_totals <- zone_dt[, .(bus_km_per_day = round(sum(bus_km), 1),
                           CO2_t_per_day  = round(sum(CO2_g) / 1e6, 2),
                           NOx_kg_per_day = round(sum(NOx_g) / 1e3, 1),
                           PM10_kg_per_day = round(sum(PM10_g) / 1e3, 2)),
                       by = .(part = ifelse(on_corridor, "Al. Jerozolimskie",
                                            "Cross and side streets"))]
zone_totals <- rbind(zone_totals, zone_totals[, .(part = "Whole zone",
  bus_km_per_day = sum(bus_km_per_day), CO2_t_per_day = sum(CO2_t_per_day),
  NOx_kg_per_day = sum(NOx_kg_per_day), PM10_kg_per_day = sum(PM10_kg_per_day))])

fwrite(zone_totals,  "outputs/tables/zone_totals.csv")
fwrite(by_street,    "outputs/tables/zone_emissions_by_street.csv")
fwrite(whole_routes, "outputs/tables/whole_route_emissions.csv")
st_write(st_transform(zone_sf, 4326), "outputs/tables/zone_links.gpkg",
         delete_dsn = TRUE, quiet = TRUE)
print(zone_totals)

# --- 7b. Whole Warsaw bus network and the full length of connected streets --------
# Every stop-to-stop bus link in Warsaw, with emissions per km of street.
warsaw_ids <- stops[town_name == corridor_town, stop_id]
net <- sum_by_pair(all_links[stop_id %in% warsaw_ids & to_stop_id %in% warsaw_ids])
message(sprintf("Cutting %s Warsaw bus links out of the shapes...",
                format(nrow(net), big.mark = ",")))
net_links <- links_to_sf(net)

# Which street does each link belong to?
#  - Al. Jerozolimskie: links that buses run ALONG it (same rule as the corridor analysis)
#  - both stops on the same street: that street
#  - a short link between two streets (<= 0.8 km, a turn at a junction): half to each
#  - a longer link that changes street (express sections, depot runs): not given to a
#    single street; it stays in the city totals as "Long link across several streets"
long_km <- 0.8
long_label <- "Long link across several streets"
s_from <- street_of[net_links$stop_id]; s_to <- street_of[net_links$to_stop_id]
pair   <- paste(net_links$stop_id, net_links$to_stop_id)
net_links$bus_km <- net_links$link_km * net_links$buses
net_links$len_km <- as.numeric(st_length(net_links)) / 1000
net_links$kind <- ifelse(pair %in% corridor_pairs, "corridor",
                  ifelse(s_from == s_to, "same",
                  ifelse(net_links$link_km <= long_km, "turn", "long")))

served_ids <- unique(st$stop_id)
connected  <- setdiff(unique(street_of[intersect(zone_stop_ids, served_ids)]),
                      c(corridor, "Unnamed"))

# Street names repeat across Warsaw: keep only the stretch of each connected street that
# is joined to the corridor zone (its connected piece), not a namesake elsewhere.
cand_conn <- st_transform(net_links, 2180)
cand_conn$st_name <- ifelse(s_from %in% connected & net_links$kind != "long", s_from,
                     ifelse(s_to %in% connected & net_links$kind != "long", s_to, NA))
cand_conn <- cand_conn[!is.na(cand_conn$st_name), ]
keep_rows <- unlist(lapply(split(seq_len(nrow(cand_conn)), cand_conn$st_name), function(i) {
  pieces <- st_cast(st_union(st_buffer(cand_conn[i, ], 30)), "POLYGON")
  touch  <- pieces[lengths(st_intersects(pieces, zone)) > 0]
  i[lengths(st_intersects(cand_conn[i, ], touch)) > 0]
}))
near_pairs <- paste(cand_conn$stop_id, cand_conn$to_stop_id)[keep_rows]
is_near <- pair %in% near_pairs

net_dt <- as.data.table(st_drop_geometry(net_links))
net_dt[, `:=`(s_from = s_from, s_to = s_to, link_row = .I, is_near = is_near)]
vals <- c("bus_km", "CO2_g", "NOx_g", "PM10_exhaust_g", "PM10_nonexhaust_g", "PM10_g")
attr_one  <- net_dt[kind != "turn"][, `:=`(street = fifelse(kind == "corridor", corridor,
                                           fifelse(kind == "same", s_from, long_label)),
                                           weight = 1)]
# a turn that touches the corridor goes wholly to the cross street (the bus does not
# travel along the corridor); other turns are split half and half
attr_turn <- rbind(net_dt[kind == "turn"][, `:=`(street = s_from,
                     weight = fifelse(s_from == corridor, 0, fifelse(s_to == corridor, 1, 0.5)))],
                   net_dt[kind == "turn"][, `:=`(street = s_to,
                     weight = fifelse(s_to == corridor, 0, fifelse(s_from == corridor, 1, 0.5)))])
attr_turn <- attr_turn[weight > 0]
attrib <- rbind(attr_one, attr_turn)
attrib[, (vals) := lapply(.SD, function(v) v * weight), .SDcols = vals]
attrib[, group := fifelse(street == corridor, "Al. Jerozolimskie",
                  fifelse(street %in% connected & is_near, "Connected street (full length)",
                  fifelse(street == long_label, long_label, "Rest of the bus network")))]

# Map group of each link (for drawing): corridor, connected if either end street is
net_links$group <- ifelse(net_links$kind == "corridor", "Al. Jerozolimskie",
                   ifelse(is_near,
                          "Connected street (full length)", "Rest of the bus network"))

sum_net <- function(dt) dt[, .(bus_km_per_day  = round(sum(bus_km), 0),
                               CO2_t_per_day   = round(sum(CO2_g) / 1e6, 2),
                               NOx_kg_per_day  = round(sum(NOx_g) / 1e3, 1),
                               PM10_kg_per_day = round(sum(PM10_g) / 1e3, 2))]
scope_totals <- rbind(attrib[, sum_net(.SD), by = .(scope = group)],
                      cbind(scope = "Whole Warsaw bus network", sum_net(attrib)))
scope_totals[, share_of_city_CO2 := round(CO2_t_per_day /
                                           CO2_t_per_day[scope == "Whole Warsaw bus network"], 3)]
attrib[group == "Rest of the bus network" & street %in% connected,
       street := paste0(street, " (elsewhere)")]
by_street_all <- attrib[street != long_label,
                        .(bus_km_per_day = round(sum(bus_km), 0),
                          CO2_kg_per_day = round(sum(CO2_g) / 1e3, 1),
                          NOx_kg_per_day = round(sum(NOx_g) / 1e3, 2),
                          PM10_g_per_day = round(sum(PM10_g), 1)),
                        by = .(street, group)][order(-CO2_kg_per_day)]
by_street_all[, rank_in_city := seq_len(.N)]
city_streets <- by_street_all
connected_streets <- by_street_all[group != "Rest of the bus network"]

# Length of street with bus service: links that stay on one street, overlaps merged,
# halved because the two directions are separate links
len_src <- st_transform(net_links[net_links$kind %in% c("corridor", "same"), ], 2180)
len_src$street_name <- ifelse(len_src$kind == "corridor", corridor,
                              street_of[len_src$stop_id])
len_src <- len_src[len_src$street_name %in% connected_streets$street, ]
street_len <- sapply(split(st_geometry(len_src), len_src$street_name),
                     function(g) as.numeric(st_length(st_union(g))) / 1000)
connected_streets[, bus_street_km := round(street_len[street] / 2, 1)]
setcolorder(connected_streets, c("street", "group", "bus_street_km"))

fwrite(scope_totals,      "outputs/tables/network_scope_totals.csv")
fwrite(connected_streets, "outputs/tables/connected_streets_full_length.csv")
fwrite(city_streets,      "outputs/tables/warsaw_bus_emissions_by_street.csv")
net_links$street <- ifelse(net_links$kind == "corridor", corridor,
                    ifelse(net_links$kind == "same", s_from,
                    ifelse(net_links$kind == "turn", paste(s_from, "/", s_to), long_label)))
st_write(net_links[, c("stop_id", "to_stop_id", "street", "kind", "group", "buses", "bus_km",
                       "CO2_g", "NOx_g", "PM10_exhaust_g", "PM10_nonexhaust_g", "PM10_g")],
         "outputs/tables/warsaw_bus_links.gpkg", delete_dsn = TRUE, quiet = TRUE)
print(scope_totals)

# --- 8. Figures ---------------------------------------------------------------------
ink <- "#0b0b0b"; ink2 <- "#52514e"; muted <- "#898781"; grid <- "#e1e0d9"
theme_set(theme_minimal(base_size = 11) +
            theme(plot.background = element_rect(fill = "#fcfcfb", colour = NA),
                  panel.grid.minor = element_blank(),
                  panel.grid.major = element_line(colour = grid, linewidth = 0.3),
                  axis.text = element_text(colour = muted),
                  axis.title = element_text(colour = ink2),
                  plot.title = element_text(colour = ink, face = "bold"),
                  plot.subtitle = element_text(colour = ink2),
                  plot.caption = element_text(colour = muted, hjust = 0)))
caption_txt <- sprintf(paste0("Scheduled weekday service on %s.\nSource: GTFS (mkuran.pl); ",
                              "EMEP/EEA Guidebook 2023 Tier 1 factors. Author: Truc Pham."),
                       format(as.Date(service_date, "%Y%m%d"), "%d %b %Y"))

net_sf <- shapes[shape_id %in% unique(bus_trips$shape_id)][
  , .(geometry = list(st_linestring(cbind(shape_pt_lon, shape_pt_lat)))), by = shape_id] |>
  st_sf(crs = 4326) |> st_transform(2180)
zone_plot <- zone_sf
zone_plot$len_km <- as.numeric(st_length(zone_plot)) / 1000
bb <- st_bbox(st_buffer(zone, 150))
lab_df <- st_transform(st_as_sf(stops[stop_id %in% corridor_stop_ids,
                                      .(lon = mean(stop_lon), lat = mean(stop_lat)),
                                      by = stop_name][stop_name %in% c(
                                        "Dw. Zachodni", "Pl. Zawiszy", "Centrum",
                                        "Łopuszańska")],
                                coords = c("lon", "lat"), crs = 4326), 2180)

pollutant_map <- function(var, unit_div, title, legend_title, high) {
  zone_plot$value <- zone_plot[[var]] / unit_div / zone_plot$len_km
  zone_plot <- zone_plot[order(zone_plot$value), ]
  ggplot() +
    geom_sf(data = net_sf, colour = "#e1e0d9", linewidth = 0.2) +
    geom_sf(data = zone, fill = NA, colour = "#c3c2b7", linewidth = 0.3, linetype = "dashed") +
    geom_sf(data = zone_plot, aes(colour = value, linewidth = on_corridor), lineend = "round") +
    geom_sf_text(data = lab_df, aes(label = stop_name), size = 2.8, colour = ink2,
                 nudge_y = 260) +
    scale_colour_gradient(low = "#cde2fb", high = high, name = legend_title) +
    scale_linewidth_manual(values = c(`TRUE` = 1.4, `FALSE` = 0.8), guide = "none") +
    coord_sf(xlim = bb[c("xmin", "xmax")], ylim = bb[c("ymin", "ymax")],
             expand = FALSE, datum = NA) +
    labs(title = title, x = NULL, y = NULL) +
    theme(legend.key.width = unit(0.4, "cm"), plot.title = element_text(size = 11))
}
p_co2 <- pollutant_map("CO2_g", 1e3, "CO2 (exhaust)", "kg per km\nper day", "#0d366b")
p_nox <- pollutant_map("NOx_g", 1, "NOx (exhaust)", "g per km\nper day", "#0d366b")
p_pm  <- pollutant_map("PM10_g", 1, "PM10 (exhaust + brake, tyre and road wear)",
                       "g per km\nper day", "#0d366b")

if (requireNamespace("patchwork", quietly = TRUE)) {
  library(patchwork)
  p_maps <- (p_co2 / p_nox / p_pm) + plot_annotation(
    title = "Bus emissions on Aleje Jerozolimskie and the streets that cross it",
    subtitle = sprintf(paste0("Every stop-to-stop bus link within %d m of the corridor; ",
                              "thick lines = Al. Jerozolimskie, thin = cross and side streets"),
                       zone_m),
    caption = caption_txt,
    theme = theme(plot.title = element_text(face = "bold", colour = ink),
                  plot.subtitle = element_text(colour = ink2),
                  plot.caption = element_text(colour = muted, hjust = 0)))
  ggsave("outputs/figures/map_pollutants_zone.png", p_maps, width = 10, height = 14, dpi = 200)
} else {
  for (x in list(list(p_co2, "co2"), list(p_nox, "nox"), list(p_pm, "pm10"))) {
    ggsave(sprintf("outputs/figures/map_%s_zone.png", x[[2]]), x[[1]] + labs(caption = caption_txt),
           width = 10, height = 5.5, dpi = 200)
  }
}

top_streets <- by_street[street != "Unnamed"][1:min(12, .N)]
top_streets[, street := factor(street, levels = rev(street))]
p_streets <- ggplot(top_streets, aes(CO2_kg_per_day, street, fill = on_corridor)) +
  geom_col(width = 0.7) +
  scale_fill_manual(values = c(`TRUE` = "#2a78d6", `FALSE` = "#86b6ef"),
                    breaks = c("TRUE", "FALSE"),
                    labels = c(`TRUE` = "Al. Jerozolimskie", `FALSE` = "Cross or side street"),
                    name = NULL) +
  labs(title = sprintf("Bus CO2 by street within %d m of the corridor", zone_m),
       subtitle = "Kilograms per weekday; cross streets counted only inside the zone",
       x = "CO2 (kg per day)", y = NULL, caption = caption_txt) +
  theme(panel.grid.major.y = element_blank(), legend.position = "top",
        legend.justification = "left")
ggsave("outputs/figures/co2_by_street_zone.png", p_streets, width = 8, height = 5.5, dpi = 200)

pm_split <- melt(by_class[, .(class_label, Exhaust = PM10_exhaust_g_per_day,
                              `Brake, tyre and road wear` = PM10_nonexhaust_g_per_day)],
                 id.vars = "class_label", variable.name = "source", value.name = "g")
pm_split[, class_label := factor(class_label, levels = rev(by_class$class_label))]
p_pm_split <- ggplot(pm_split, aes(g, class_label, fill = source)) +
  geom_col(width = 0.7, colour = "#fcfcfb", linewidth = 0.4) +
  scale_fill_manual(values = c(Exhaust = "#eb6834", `Brake, tyre and road wear` = "#2a78d6"),
                    name = NULL) +
  labs(title = "PM10 on Al. Jerozolimskie by bus type",
       subtitle = "Electric buses emit no exhaust but still wear brakes, tyres and road",
       x = "PM10 (g per day)", y = NULL, caption = caption_txt) +
  theme(panel.grid.major.y = element_blank(), legend.position = "top",
        legend.justification = "left")
ggsave("outputs/figures/pm10_exhaust_vs_nonexhaust.png", p_pm_split, width = 8, height = 4.5,
       dpi = 200)

km_route <- trip_summary[, .(bus_km = sum(corridor_km)), by = .(route, powertrain)]
top_routes <- km_route[, .(total = sum(bus_km)), by = route][order(-total)][1:min(15, .N), route]
km_route <- km_route[route %in% top_routes][, route := factor(route, levels = rev(top_routes))]
p_routes <- ggplot(km_route, aes(bus_km, route, fill = powertrain)) +
  geom_col(width = 0.7, colour = "#fcfcfb", linewidth = 0.4) +
  scale_fill_manual(values = c(diesel = "#eb6834", electric = "#2a78d6"),
                    labels = c(diesel = "Diesel", electric = "Electric"), name = NULL) +
  labs(title = "Bus-kilometres on the corridor per weekday, top 15 routes",
       subtitle = "Only the diesel share produces exhaust emissions",
       x = "Bus-km per day on Al. Jerozolimskie", y = "Route", caption = caption_txt) +
  theme(panel.grid.major.y = element_blank(), legend.position = "top",
        legend.justification = "left")
ggsave("outputs/figures/bus_km_by_route.png", p_routes, width = 8, height = 6, dpi = 200)

p_hour <- ggplot(by_hour, aes(hour, buses)) +
  geom_col(fill = "#2a78d6", width = 0.8) +
  scale_x_continuous(breaks = seq(3, 30, 3), labels = function(h) sprintf("%02d:00", h %% 24)) +
  labs(title = "Buses entering the corridor by hour",
       subtitle = "Bars after midnight are night buses from the same service day",
       x = "Hour of day", y = "Buses per hour", caption = caption_txt) +
  theme(panel.grid.major.x = element_blank())
ggsave("outputs/figures/buses_by_hour.png", p_hour, width = 8, height = 4, dpi = 200)


# --- 9. Network figures ---------------------------------------------------------------
net_plot <- st_transform(net_links, 2180)
corr_plot <- net_plot[net_plot$group == "Al. Jerozolimskie", ]
city_note <- "Streets without bus service (most small residential streets) carry no bus emissions and are not shown."

network_map <- function(data, var, unit_div, title, legend_title, extent = NULL) {
  data$value <- data[[var]] / unit_div / pmax(data$len_km, 0.01)
  cap <- quantile(data$value, 0.98, na.rm = TRUE)
  data <- data[order(data$value), ]
  p <- ggplot() +
    geom_sf(data = data, aes(colour = value), linewidth = 0.35) +
    geom_sf(data = corr_plot, colour = ink, linewidth = 1.3) +
    geom_sf(data = corr_plot, aes(colour = value), linewidth = 0.6,
            inherit.aes = FALSE) +
    scale_colour_gradient(low = "#cde2fb", high = "#0d366b", limits = c(0, cap),
                          oob = scales::squish, trans = "sqrt", name = legend_title) +
    labs(title = title, x = NULL, y = NULL) +
    theme(legend.key.width = unit(0.35, "cm"), plot.title = element_text(size = 11),
          panel.grid.major = element_blank(), axis.text = element_blank())
  if (!is.null(extent)) {
    p <- p + coord_sf(xlim = extent[c("xmin", "xmax")], ylim = extent[c("ymin", "ymax")],
                      expand = FALSE, datum = NA)
  } else {
    p <- p + coord_sf(datum = NA)
  }
  p
}
corr_plot$value <- NULL
co2_city <- network_map(net_plot, "CO2_g", 1e3, "CO2 (exhaust)", "kg per km\nper day")
nox_city <- network_map(net_plot, "NOx_g", 1,   "NOx (exhaust)", "g per km\nper day")
pm_city  <- network_map(net_plot, "PM10_g", 1,  "PM10 (exhaust + wear)", "g per km\nper day")
# corridor overlay needs its own value per panel
fix_overlay <- function(p, var, unit_div) {
  p$layers[[3]]$data <- within(corr_plot, value <- corr_plot[[var]] / unit_div /
                                 pmax(corr_plot$len_km, 0.01))
  p
}
co2_city <- fix_overlay(co2_city, "CO2_g", 1e3)
nox_city <- fix_overlay(nox_city, "NOx_g", 1)
pm_city  <- fix_overlay(pm_city,  "PM10_g", 1)

if (requireNamespace("patchwork", quietly = TRUE)) {
  p_city <- (co2_city | nox_city | pm_city) + plot_annotation(
    title = "Bus emissions on every bus street in Warsaw",
    subtitle = "Per km of street per weekday, both directions drawn; Al. Jerozolimskie outlined in black",
    caption = paste0(caption_txt, "\n", city_note),
    theme = theme(plot.title = element_text(face = "bold", colour = ink),
                  plot.subtitle = element_text(colour = ink2),
                  plot.caption = element_text(colour = muted, hjust = 0)))
  ggsave("outputs/figures/map_warsaw_bus_network.png", p_city, width = 15, height = 5.8, dpi = 200)
}

# Connected streets over their full length
conn_plot <- net_plot[net_plot$group != "Rest of the bus network", ]
conn_plot$value <- conn_plot$CO2_g / 1e3 / pmax(conn_plot$len_km, 0.01)
ext <- st_bbox(st_buffer(st_as_sfc(st_bbox(conn_plot)), 300))
p_conn <- ggplot() +
  geom_sf(data = net_plot, colour = "#e1e0d9", linewidth = 0.25) +
  geom_sf(data = conn_plot[order(conn_plot$value), ], aes(colour = value), linewidth = 0.6) +
  geom_sf(data = corr_plot, colour = ink, linewidth = 1.4) +
  scale_colour_gradient(low = "#cde2fb", high = "#0d366b",
                        limits = c(0, quantile(conn_plot$value, 0.98)), oob = scales::squish,
                        trans = "sqrt", name = "CO2, kg per km\nper day") +
  coord_sf(xlim = ext[c("xmin", "xmax")], ylim = ext[c("ymin", "ymax")],
           expand = FALSE, datum = NA) +
  labs(title = "Al. Jerozolimskie and every street connected to it, full length",
       subtitle = sprintf("%d streets that cross or join the corridor; corridor in black, rest of the bus network in grey",
                          length(connected)),
       x = NULL, y = NULL, caption = paste0(caption_txt, "\n", city_note)) +
  theme(panel.grid.major = element_blank())
asp <- as.numeric((ext["ymax"] - ext["ymin"]) / (ext["xmax"] - ext["xmin"]))
ggsave("outputs/figures/map_connected_streets.png", p_conn, width = 11,
       height = min(11, 1.6 + 9 * asp), dpi = 200)

top_conn <- connected_streets[1:min(15, .N)]
top_conn[, street_lab := factor(street, levels = rev(street))]
p_conn_bar <- ggplot(top_conn, aes(CO2_kg_per_day, street_lab,
                                   fill = group == "Al. Jerozolimskie")) +
  geom_col(width = 0.7, show.legend = FALSE) +
  geom_text(aes(label = sprintf("#%d in Warsaw", rank_in_city)), hjust = -0.1, size = 3,
            colour = ink2) +
  scale_fill_manual(values = c(`TRUE` = "#2a78d6", `FALSE` = "#86b6ef")) +
  scale_x_continuous(expand = expansion(mult = c(0, 0.18))) +
  labs(title = "Bus CO2 on the corridor and its connected streets, full length",
       subtitle = "Kilograms per weekday; label = the street's rank among all Warsaw bus streets",
       x = "CO2 (kg per day)", y = NULL, caption = caption_txt) +
  theme(panel.grid.major.y = element_blank())
ggsave("outputs/figures/co2_connected_streets.png", p_conn_bar, width = 8.5, height = 6, dpi = 200)

message("Done. Tables in outputs/tables, figures in outputs/figures.")
