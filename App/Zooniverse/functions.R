#functions
library(dplyr)
library(ggplot2)
library(leaflet)
library(sf)
library(gridExtra)
library(stringr)
library(htmltools)
library(tidyr)

#Site map
create_map<-function(colonies){
  m <- leaflet(data=colonies) %>% addTiles() %>% addMarkers(popup =~colony) 
  return(renderLeaflet(m))
}

#Load data
load_classifications<-function(){
  raw_data<-read_sf("data/everglades-watch-classifications.shp")
  st_crs(raw_data)<-32617
  return(raw_data)
}

#Filter classification by spatial overlap
#TODO handle tie breaks better.

check_events<-function(x){
  if(str_detect(x,"_")){
    return(str_match(x,"(\\w+)_")[,2])
  }else{
    return(x)
  }
}
filter_annotations<-function(raw_data){
  selected_ids<-unique(raw_data$selected_i)
  
  #Majority rule for labels
  majority_rule<-raw_data %>%
                 data.frame() %>% # Converting to a non-spatial data frame improves speed 100-200x
                 group_by(selected_i, label) %>%
                 summarize(n=n()) %>%
                 arrange(desc(n)) %>%
                 slice(1) %>%
                 as.data.frame() %>%
                 mutate(majority_class=label) %>%
                 dplyr::select(selected_i,majority_class)
  
  selected_boxes<-raw_data %>% filter(selected_i %in% selected_ids) %>% inner_join(majority_rule) %>% filter(!is.na(event))
  
  #!!Temp hotfix!!! until events are seperated from dates
  #selected_boxes$event<-sapply(selected_boxes$event,check_events)
  selected_boxes$event[selected_boxes$event %in% "03112020"]<-gsub(x=selected_boxes$event[selected_boxes$event %in% "03112020"],pattern="03112020",replacement="03_11_2020")
  
  selected_boxes$event<-as.Date(selected_boxes$event,"%m_%d_%Y")
  selected_boxes$tileset_id<-construct_id(selected_boxes$site,selected_boxes$event)
  
  #get unique boxes among observers
  
  return(selected_boxes)
}

totals_plot<-function(selected_boxes){
  ggplot(selected_boxes) + geom_bar(aes(x=species)) + coord_flip() + ggtitle("Project Total") + labs(x="Label") + theme(text = element_text(size=20))
}

site_totals<-function(selected_boxes){
  #Site totals
  selected_sites <-selected_boxes %>% group_by(site) %>% summarize(n=n()) %>% filter(n>2)
  to_plot<-selected_boxes %>% group_by(site,species) %>% summarize(n=n()) %>% filter(site %in% selected_sites$site)
  ggplot(to_plot) + geom_col(aes(x=species,y=n,fill=site),position = position_dodge()) + coord_flip() + labs(x="Label",y="Count",fill="Site") +
    theme(text = element_text(size=20))
}

site_phenology<-function(selected_boxes){
  to_plot<-selected_boxes %>% group_by(event,species,behavior) %>% summarize(n=n()) 
  ggplot(to_plot,aes(x=event,y=n,col=species,shape=behavior)) + geom_point(size=5) + geom_line(size=1) + labs(x="Event",y="Count",col="label") + stat_smooth() +
    theme(text = element_text(size=20))
}

plot_annotations<-function(selected_boxes, MAPBOX_ACCESS_TOKEN){
  pal <- colorFactor(
    palette = 'Dark2',
    domain = selected_boxes$species
  )
  
  selected_centroids<-st_transform(selected_boxes,4326)
  
  #Create mapbox tileset
  mapbox_tileset<-unique(selected_centroids$tileset_id)
  mapbox_tileset<-paste("bweinstein.",mapbox_tileset,sep="")
  
  m<-leaflet(data=selected_centroids) %>%
    addProviderTiles("MapBox", options = providerTileOptions(id = mapbox_tileset, minZoom = 8, maxNativeZoom=24, maxZoom = 24, accessToken = MAPBOX_ACCESS_TOKEN)) %>%
    addCircles(stroke = T,color=~pal(species),fillOpacity = 0.1,radius = 0.25,popup = ~htmlEscape(label))
  return(m)
}

plot_predictions<-function(df, MAPBOX_ACCESS_TOKEN){
  mapbox_tileset<-unique(df$tileset_id)
  mapbox_tileset<-paste("bweinstein.",mapbox_tileset,sep="")
  
  m<-leaflet(data=df) %>% 
    addProviderTiles("MapBox", options = providerTileOptions(id = mapbox_tileset, minZoom = 8, maxNativeZoom=24, maxZoom = 24, accessToken = MAPBOX_ACCESS_TOKEN)) %>%
    addCircles(stroke = T,fillOpacity = 0.1,radius = 0.25,popup = ~htmlEscape(paste(label,round(score,2),sep=":")))
  return(m)
}

behavior_heatmap<-function(selected_boxes){
  class_totals<-selected_boxes %>% group_by(majority_class) %>% summarize(total=n())
  p<-selected_boxes %>% group_by(majority_class,behavior) %>% summarize(n=n()) %>% as.data.frame() %>% select(-geometry) %>% 
    inner_join(class_totals) %>% mutate(prop=n/total * 100) %>% ggplot(.) + 
    geom_tile(aes(x=majority_class,y=behavior,fill=n)) + 
    scale_fill_continuous(low="blue",high="red") + 
    labs(x="Label",y="Behavior",fill="% of Label Total") + theme(axis.text.x  = element_text(angle = -90),text = element_text(size=20))
  plot(p)
}

time_predictions<-function(df){
  #only plot sites with more than one event
  site_names <- df %>% as.data.frame() %>% select(site,event) %>% group_by(site) %>% summarize(n=length(unique(event))) %>% filter(n>1) %>% .$site
  df %>% group_by(site,event) %>% filter(site %in% site_names) %>% summarize(n=n()) %>% ggplot(.,aes(x=event,y=n)) + geom_point() + geom_line() + facet_wrap(~site,ncol=3,scales="free") + labs(y="Predicted Birds",x="Date") + theme(text = element_text(size=20))
}

compare_counts<-function(df, selected_boxes){
  automated_count<-data.frame(df) %>% select(site,event) %>% group_by(site,event) %>% summarize(predicted=n())
  zooniverse_count<-data.frame(selected_boxes) %>% select(user_name,site,event) %>% group_by(user_name,site,event) %>% summarize(Zooniverse=n())
  comparison_table<-automated_count %>% inner_join(zooniverse_count) %>% mutate(event=as.character(event)) %>% pivot_wider(names_from = user_name,values_from = Zooniverse)
  return(comparison_table)
}

##Nest detection
nest_summary_table<-function(nestdf, min_detections){
  nest_table <- nestdf %>%
                  as.data.frame() %>%
                  group_by(Site, Year, target_ind) %>%
                  summarize(n=n()) %>%
                  filter(n >= min_detections) %>%
                  group_by(Site, Year) %>%
                  summarize(Nests=n(), Average_Detections = mean(n)) 
  return(nest_table)
}

nest_history<-function(dat){
  dat<-dat %>% group_by(Site) %>%
    mutate(reindex=as.character(as.numeric(as.factor(target_ind))),Date=as.Date(Date,"%m_%d_%Y"))
  
  date_order<-data.frame(o=unique(dat$Date),j=format(unique(dat$Date),format="%j")) %>% arrange(j)
  
  #don't plot if there aren't multiple dates
  if(nrow(date_order)==0){return(NA)}
  
  dat$factorDate<-factor(dat$Date,labels=format(date_order$o,format="%b-%d"),ordered = T)
  #set order
  ggplot(dat, aes(x=reindex,y=factorDate)) + facet_wrap(~Site,scales="free",ncol=2) + geom_tile() + coord_flip() + theme(axis.text.y = element_blank()) + labs(x="Nest",y="Date") +
    theme(axis.text.x  = element_text(angle = -90),text = element_text(size=20)) 
}

species_colors <- colorFactor(palette = c("yellow", "blue",
                                          "#ff007f", "brown",
                                          "purple", "white"),
                              domain = c("Great Egret", "Great Blue Heron",
                                         "Roseate Spoonbill", "Wood Stork",
                                          "Snowy Egret", "White Ibis"),
                              ordered=TRUE)

plot_nests<-function(df, bird_df, MAPBOX_ACCESS_TOKEN){
  mapbox_tileset<-unique(df$tileset_id)[1]
  mapbox_tileset<-paste("bweinstein.",mapbox_tileset,sep="")

  m<-leaflet(data=df) %>% 
    addProviderTiles("MapBox", layerId = "mapbox_id",options = providerTileOptions(id = mapbox_tileset, minZoom = 8, maxNativeZoom=24, maxZoom = 24, accessToken = MAPBOX_ACCESS_TOKEN)) %>%
    addCircles(stroke = T,fillOpacity = 0.1,radius = 0.5,popup = ~htmlEscape(paste(Date,round(score,2),target_ind,sep=":"))) %>%
    addCircles(data = bird_df, stroke = T, fillOpacity = 0, radius = 0.2, color = ~species_colors(label),
               popup = ~htmlEscape(paste(round(score,2), bird_id, sep=":")))
  return(m)
}

update_nests<-function(mapbox_tileset, df, bird_df, field_nests,
                       MAPBOX_ACCESS_TOKEN, focal_position = NULL){
  mapbox_tileset<-paste("bweinstein.",mapbox_tileset,sep="")
  lng <- focal_position[1]
  lat <- focal_position[2]
  zoom <- 24
  if (is.null(lng) | is.null(lat) | is.null(zoom) | is.null(focal_position)){    
    leafletProxy("nest_map")  %>% clearShapes() %>%
      addProviderTiles("MapBox", layerId = "mapbox_id",options = providerTileOptions(id = mapbox_tileset, minZoom = 8, maxNativeZoom=24, maxZoom = 24, accessToken = MAPBOX_ACCESS_TOKEN)) %>%
      addCircles(data=df,stroke = T,fillOpacity = 0.1,radius = 0.5,popup = ~htmlEscape(paste(Date,round(score,2),target_ind,sep=", "))) %>%
      addCircles(data = bird_df, stroke = T, fillOpacity = 0, radius = 0.2, color = ~species_colors(label),
                 popup = ~htmlEscape(paste(round(score,2), bird_id, sep=":")))
  } else {
    leafletProxy("nest_map")  %>% clearShapes() %>%
      addProviderTiles("MapBox", layerId = "mapbox_id",options = providerTileOptions(id = mapbox_tileset, minZoom = 8, maxNativeZoom=24, maxZoom = 24, accessToken = MAPBOX_ACCESS_TOKEN)) %>%
      addCircles(data = focal_position, stroke = T, fillOpacity = 0, radius = .8, color="orange") %>% 
      addCircles(data=df,stroke = T,fillOpacity = 0.1,radius = 0.5,popup = ~htmlEscape(paste(Date,round(score,2),target_ind,sep=", "))) %>%
      addCircles(data = bird_df, stroke = T, fillOpacity = 0, radius = 0.2, color = ~species_colors(label),
                 popup = ~htmlEscape(paste(round(score,2), bird_id, sep=":"))) %>%
      setView(lng, lat, zoom)
  }
}

#Construct mapbox url
construct_id<-function(site,event){
  event_formatted<-format(event, "%m_%d_%Y")
  tileset_id <- paste(site,"_",event_formatted,sep="")
  return(tileset_id)
}

zooniverse_complete<-function(){
  #Load subject data
  subject_data<-read.csv("data/everglades-watch-subjects.csv")
  raw_annotations<-read.csv("data/parsed_annotations.csv")
  subject_data$Site<-sapply(subject_data$metadata, function(x) str_match(gsub('\"', "", x, fixed = TRUE),"site:(\\w+)")[,2])
  
  #images per site
  completed<-subject_data %>% group_by(Site) %>% mutate(annotated=subject_id %in% raw_annotations$subject_ids) %>% select(Site,subject_id, annotated) %>% group_by(Site, annotated) %>% summarize(n=n_distinct(subject_id)) %>% 
    tidyr::spread(annotated,n, fill=0) %>% mutate(Percent_Complete=`TRUE`/(`TRUE`+`FALSE`)*100)
  p<-ggplot(completed,aes(x=Site,y=Percent_Complete)) + coord_flip() + geom_bar(stat="identity") + labs(y="Annotated (%)",x="Subject Set") 
  return(p)
  }
