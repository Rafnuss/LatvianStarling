library(GeoPressureR)
library(leaflet)
library(leaflet.providers)
library(leaflet.extras)
library(ggplot2)
library(plotly)
library(RColorBrewer)
library(dplyr)
library(raster)
library(readxl)

# Set debug T to see all check and set to F once everything is correct
debug <- F

# Define the geolocator data logger id to use
# DONE: 24YN, 24YK, 24YJ 24YH (might need some further twicking), 24YG, 24XE, 24XB 24VF24VR
#    24WA

# gdl <- "24WA"

# Read its information from gpr_settings.xlsx
gpr <- read_excel("data/gpr_settings.xlsx") %>%
  filter(gdl_id == gdl)

# Read, classify and label ----
if (debug) {
  # Use this figure to determine crop and calib period. You can then use it again to check that they are correct.
  pam_no_crop <- pam <- pam_read(paste0("data/0_PAM/", gpr$gdl_id))

  p <- ggplot()
  if (!is.na(gpr$calib_1_start)&!is.na(gpr$calib_1_end)){
    p <- p + geom_rect(aes(xmin = gpr$calib_1_start, xmax = gpr$calib_1_end, ymin=min(pam_no_crop$pressure$obs), ymax=max(pam_no_crop$pressure$obs)), fill="grey")
  }
  if (!is.na(gpr$calib_2_start)&!is.na(gpr$calib_2_end)){
    p <- p + geom_rect(aes(xmin = gpr$calib_2_start, xmax = gpr$calib_2_end, ymin=min(pam_no_crop$pressure$obs), ymax=max(pam_no_crop$pressure$obs)), fill="grey")
  }
  if (!is.na(gpr$crop_start)){
    p <- p + geom_vline(xintercept = gpr$crop_start, color = "green", lwd = 1)
  }
  if (!is.na(gpr$crop_end)){
    p <- p + geom_vline(xintercept = gpr$crop_end, color = "red", lwd = 1)
  }
  p <- p +
    geom_line(data = pam_no_crop$pressure, aes(x = date, y = obs), col = "black") +
    geom_line(data = pam_no_crop$acceleration, aes(x = date, y = obs), col = "black") +
    theme_bw() +
    scale_y_continuous(name = "Pressure (hPa)")

  ggplotly(p, dynamicTicks = T) %>% layout(showlegend = F)
}


pam <- pam_read(paste0("data/0_PAM/", gpr$gdl_id),
                crop_start = gpr$crop_start,
                crop_end = gpr$crop_end
)

# Auto classification + writing, only done the first time
if (!file.exists(paste0("data/1_pressure/labels/", gpr$gdl_id, "_act_pres-labeled.csv"))) {
  pam <- pam_classify(pam)
  trainset_write(pam, "data/1_pressure/labels/")
  browseURL("https://trainset.geocene.com/")
  invisible(readline(prompt = paste0(
    "Edit the label file data/1_pressure/labels/", gpr$gdl_id,
    "_act_pres.csv.\n Once you've exported ", gpr$gdl_id,
    "_act_pres-labeled.csv, press [enter] to proceed"
  )))
}

# Read the label and compute the stationary info
if (file.exists(paste0("data/1_pressure/labels/", pam$id, "_act_pres-diff-labeled.csv"))){
  pam <- trainset_read(pam, "data/1_pressure/labels/", filename = paste0(pam$id, "_act_pres-diff-labeled.csv"))
} else {
  pam <- trainset_read(pam, "data/1_pressure/labels/")
}

pam <- pam_sta(pam)

# define the discrete colorscale. Used at multiple places.
col <- rep(RColorBrewer::brewer.pal(9, "Set1"), times = ceiling((nrow(pam$sta) + 1) / 9))
col <- col[1:(nrow(pam$sta) + 1)]
names(col) <- levels(factor(c(0, pam$sta$sta_id)))


if (debug) {
  # Test 1 ----
  pam$sta %>%
    mutate(
      duration = difftime(end, start, units = "hours"),
      next_flight_duration = difftime(lead(start), end, units = "hours")
    ) %>%
    filter(duration < 3) %>%
    arrange(duration)


  # Test 2 ----
  pressure_na <- pam$pressure %>%
    mutate(obs = ifelse(isoutlier | sta_id == 0, NA, obs))

  p <- ggplot() +
    geom_line(data = pam$pressure, aes(x = date, y = obs), col = "grey") +
    geom_line(data = pressure_na, aes(x = date, y = obs, color = factor(sta_id))) +
    # geom_point(data = subset(pam$pressure, isoutlier), aes(x = date, y = obs), colour = "black") +
    theme_bw() +
    scale_color_manual(values = col) +
    scale_y_continuous(name = "Pressure (hPa)")

  ggplotly(p, dynamicTicks = T) %>% layout(showlegend = F)
}


# Query pressure map
# We overwrite the setting parameter for resolution to make query faster at first
pressure_maps <- geopressure_map(pam$pressure,
  extent = c(gpr$extent_N, gpr$extent_W, gpr$extent_S, gpr$extent_E),
  scale = gpr$map_scale,
  max_sample = gpr$map_max_sample,
  margin = gpr$map_margin
)

# Convert to probability map
pressure_prob <- geopressure_prob_map(pressure_maps,
  s = gpr$prob_map_s,
  thr = gpr$prob_map_thr
)

if (debug) {
  # Compute the path of the most likely position
  path <- geopressure_map2path(pressure_prob)

  # Query timeserie of pressure based on these path
  pressure_timeserie <- geopressure_ts_path(path, pam$pressure, include_flight = c(0, 1))
  # pressure_timeserie <- shortest_path_timeserie
  pressure_ts_bind <- do.call("rbind", pressure_timeserie) %>%
    filter(!is.na(sta_id))

  # Test 3 ----
  p <- ggplot() +
    geom_line(data = pam$pressure, aes(x = date, y = obs), colour = "grey") +
    geom_point(data = subset(pam$pressure, isoutlier), aes(x = date, y = obs), colour = "black") +
    geom_line(data = pam$pressure %>%
                mutate(obs = ifelse(isoutlier | sta_id == 0, NA, obs)),
              aes(x = date, y = obs, color = factor(sta_id)), size = 0.5) +
    geom_line(data = pressure_ts_bind %>% filter(sta_id > 0), aes(x = date, y = pressure0, col = factor(sta_id)), linetype = 2) +
    theme_bw() +
    scale_colour_manual(values = col) +
    scale_y_continuous(name = "Pressure(hPa)")

  ggplotly(p, dynamicTicks = T) %>% layout(showlegend = F)

  # Test 4 ----
  # You might also want to adjust the value of s in `geopressure_prob_map()` based on the SD value
  # of these histogram gpr$prob_map_s
  pam$pressure %>%
    left_join(pressure_ts_bind %>% dplyr::select(c("date","pressure0")), by="date") %>%
    mutate(diff=ifelse(is.na(pressure0), 0, obs-pressure0)) %>%
    filter(sta_id > 0 & !isoutlier) %>%
    group_by(sta_id) %>%
    mutate(sta_id = paste0(sta_id, " (SD=",round(sd(diff),2)," ; N=",n(),")")) %>%
    ggplot( aes(x=diff)) +
    geom_histogram(aes(y=(..count..)/tapply(..count..,..PANEL..,sum)[..PANEL..]), binwidth=.4) +
    facet_wrap(~sta_id) +
    scale_x_continuous(name = "Pressure Geolocator - best match ERA5 (hPa)") +
    scale_y_continuous(name = "Normalized histogram")

  # Map the most likely position
  sta_duration <- unlist(lapply(pressure_prob, function(x) {
    as.numeric(difftime(metadata(x)$temporal_extent[2], metadata(x)$temporal_extent[1], units = "days"))
  }))
  pal <- colorFactor(col, as.factor(seq_len(length(col))))
  leaflet() %>%
    addProviderTiles(providers$Stamen.TerrainBackground) %>%
    addFullscreenControl() %>%
    addPolylines(lng = path$lon, lat = path$lat, opacity = 0.7, weight = 1, color = "#808080") %>%
    addCircles(lng = path$lon, lat = path$lat, opacity = 1, color = pal(factor(path$sta_id, levels = pam$sta$sta_id)), weight = sta_duration^(0.3) * 10)
}


# Save ----
save(
  # pressure_timeserie, # can be removed in not in debug mode
  pressure_prob,
  pam,
  gpr,
  file = paste0("data/1_pressure/", gpr$gdl_id, "_pressure_prob.Rdata")
)
