
# Setup  ----

library(tidyverse)
library(gridExtra)
library(RODBC)
library(mgcv)
# library(mgcViz)
library(visreg)
library(mice)
library(lubridate)
library(RColorBrewer)
# library(pammtools)
theme_set(theme_bw())
library(wesanderson)
library(plotly)
pal.name <- "Zissou1"
wid = 704
hei = 704*9/16


specie_name = 'Red-capped Robin Chat'

## Read and pre-process data  ----

capture <- read.csv('../data/ringing_data.csv') %>% 
  filter(Location=='Mwamba Plot 28, Watamu' | Location=='Mwamba plot 28') %>% 
  filter(! NettingSite %in% c('Beach','boat shed','DINING ROOM','Compost','by compost','Kilifi Bofa','Mwamba Dining Room','by volunteer rooms','Spring trap by lamp post','Office','Net by bird bath.','compost site','Bird Bath')) %>% 
  filter(! SessionNotes %in% c('Net at birdbath; BC = Bernard Chege','1 net behind birdbath')) %>% 
  #  filter( !SessionID %in% c()) %>%  !NetsOpen>8 & NetsDuration>7 
  mutate(DayOfYear = Julian) %>% 
  #filter(Date>'2003-01-01'&Date<'2019-01-01')
  mutate(
    NetsOther = str_replace(NetsOther, '11 total', '11'),
    NetsOther = str_replace(NetsOther, '10mx3','30'),
    NetsOther = str_replace(NetsOther, '10m x3','11'),
    NetsOther = str_replace(NetsOther, '2 10m','20'),
    NetsOther = str_replace(NetsOther, '1x10m','10'),
    NetsOther = str_replace(NetsOther, '10m x1','10'),
    NetssOther = str_replace(NetsOther, '10m x 1','10'),
    NetsOther = str_replace(NetsOther, '10mx2','20'),
    NetsOther = str_replace(NetsOther, '10mx1','10'),
    NetsOther = str_replace(NetsOther, '10m x 1','10'),
    NetsOther = str_replace(NetsOther, '10x1','10'),
    NetsOther = str_replace(NetsOther, '14x1, 10','24'),
    NetsOther = str_replace(NetsOther, '14x1,10','24'),
    NetsOther = str_replace(NetsOther, '10x3','30'),
    NetsOther = replace_na(NetsOther, '0'),
    NetsOther = as.numeric(NetsOther),
    NetsLength = Nets6m*6 + Nets9m*9 + Nets12m*12 + Nets18m*18 + NetsOther,
    NetsLength = ifelse(NetsLength==0,NA,NetsLength),
    NetsDuration = as.POSIXct(NetsClosed)-as.POSIXct(NetsOpen),
    NetsOpen =  hour(as.POSIXct(NetsOpen)) + minute(as.POSIXct(NetsOpen))/60,
    WeatherCat = ifelse(!is.na(Weather), 'none', NA),
    WeatherCat = ifelse(grepl('rain',Weather), 'little', WeatherCat),
    WeatherCat = ifelse(grepl('drizzle',  Weather), 'little', WeatherCat),
    WeatherCat = ifelse(grepl('shower' , Weather), 'little', WeatherCat),
    WeatherCat = ifelse(grepl('heavy' , Weather), 'strong', WeatherCat),
  ) %>% 
  mutate(
    NetsLength = ifelse(SessionID==971,NA,NetsLength), # remove aberant data
    NetsOpen = ifelse(SessionID==517,6,NetsOpen), # correct 18:00->6
    NetsDuration = ifelse(SessionID==637,NA,NetsDuration), # correct 18:00->6
    NetsOpen = ifelse(NetsOpen>7|NetsOpen<5.5, NA, NetsOpen),
 #   NetsDuration = ifelse(!(abs(NetsDuration - median(NetsDuration, na.rm = T)) < 3*sd(NetsDuration, na.rm = T)),NA,NetsDuration),
    ) %>% 
  arrange(Date) %>%
  select(SessionID,RingNo,Age,Sex,CommonName,Date,Year,Month,DayOfYear,NetsLength,NetsOpen,NetsDuration,WeatherCat,Weight) %>% 
  group_by(Year) %>% # compute the number of RCRC captured this year so far
  mutate(n = ifelse(is.na(CommonName) | CommonName!=specie_name ,0,1), 
         CountOfYear = cumsum(n)) %>% # 
  ungroup %>% 
  group_by(RingNo) %>% 
  mutate(isFirstCaptureOfYear = !(Year==lag(Year, default=FALSE))) %>% # first capture of RCRC of this year
  ungroup() 

 session <- capture %>%   
  group_by(Date) %>% 
  summarize(
    Date = as.Date(first(Date)), 
    DayOfYear = median(DayOfYear), 
    Year = median(Year), 
    Count = sum(CommonName==specie_name, na.rm = TRUE), 
    CountFoY = sum(CommonName==specie_name & isFirstCaptureOfYear, na.rm = TRUE), 
    CountAd = sum(CommonName==specie_name & Age != 0 & Age==4 & isFirstCaptureOfYear, na.rm = TRUE),
    CountJuv = sum(CommonName==specie_name & Age != 0 & Age!=4 & isFirstCaptureOfYear, na.rm = TRUE),
    NetsLength = median(NetsLength),
    NetsOpen = median(NetsOpen),
    NetsDuration = as.numeric(median(NetsDuration)),
    WeatherCat = as.factor(first(WeatherCat)),
    .groups="drop_last") %>% 
  group_by(Year) %>% # compute the number of RCRC capture so far this year
  mutate(CumCountFoY = cumsum(CountFoY)-ifelse(is.na(CountFoY),0,CountFoY)) %>%
  ungroup() %>% arrange(Date) %>% filter(DayOfYear>100 & DayOfYear<340)

tf = function(t){
  paste0(
    'M=', format(as.POSIXct(Sys.Date() + mean(t,na.rm=T)/24), "%H:%M", tz="UTC"), ' ; SD=',
    format(as.POSIXct(Sys.Date() + sd(t,na.rm=T)/24), "%H:%M", tz="UTC")
  )
}

## Imputing data  ----

session.imputed <- session %>% 
  # bind_rows(session %>% mutate(DayOfYear = DayOfYear+360)) %>% 
  mice(print=F, m = 30, seed=123456789) %>% 
  complete("all")


capture2020 <- read.csv('../data/ringing_mwamba_rcrc_2020.csv') %>% 
 filter(Location=='Mwamba') %>% 
  mutate(
    Date=dmy(date),
    CloseTime = hour(hm(CloseTime)) + minute(hm(CloseTime))/60,
    NetsOpen = hour(hm(OpenTime)) + minute(hm(OpenTime))/60,
    NetsDuration = CloseTime-NetsOpen,
    n = !(Notes=="No RCRC"),
    CountOfYear = cumsum(n),
    isFirstCaptureOfYear = !NewRetrap=="R",
    #NetsLength = 
    ) %>% 
  select(RingNo, Age, Date, NetsOpen, NetsDuration, Notes, isFirstCaptureOfYear,CountOfYear)
  
session2020 <- capture2020 %>% 
  group_by(Date) %>% 
  summarize(
    DayOfYear = as.numeric(format(Date, "%j")),
    Count = sum( !(Notes=="No RCRC"), na.rm = T ),
    CountFOY = sum( !(Notes=="No RCRC")&isFirstCaptureOfYear , na.rm = T ),
    CountJuv = sum(Age==3, na.rm = T),
    CountAd = sum(Age==4, na.rm = T),
    NetsOpen = median(NetsOpen),
    NetsDuration = median(NetsDuration),
    .groups="drop_last"
  ) %>% unique()%>% mutate(
    CumCountFoY = cumsum(CountFOY),
  )




# Capture model ----

##  Step 1 ---- 
mod=list(); i<-0
for(d in session.imputed){
  i<-i+1
  a = d %>% mutate(Year=factor(Year))
  #mod[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY + WeatherCat + NetsOpen, family=poisson(), data=a)
  mod[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY, family=poisson(), data=a)
  # mod[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength, family=poisson(), data=a)
  # mod[[i]] <- gamm( CountFoY ~ Year + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY, random=list(Year=~1), family=poisson(), data = a ) ## Year 
   #
} 
summary(mod[[1]])
par(mfrow=c(3,2), mar = c(2, 2, 0, 0))
visreg(mod[[1]], scale="response",ylim=c(0,6))


### Model selection
a = session.imputed[[1]]

tmp  <- gam( CountFoY ~ s(Year) + s(DayOfYear) + NetsDuration + NetsLength + NetsOpen + WeatherCat + CumCountFoY, family=poisson(), data=a)
summary(tmp)
visreg(tmp)

par(mfrow=c(3,2), mar = c(2, 2, 0, 0))
visreg(tmp, scale="response",ylim=c(0,9))


##  Step 2 ---- 

# modFoY = capture %>% 
#   filter(CommonName==specie_name) %>% 
#   glm(formula = isFirstCaptureOfYear ~ CountOfYear, family = "binomial")
# 
# visreg(modFoY)
# 
# predictmodFOY <- data.frame(CountOfYear = seq(1,max(capture$CountOfYear,na.rm = T))) %>%
#   mutate(
#     fit.link = predict(modFoY, ., type = "link"),
#     se.fit.link = predict(modFoY, ., type = "link", se.fit = T) %>% .$se.fit,
#     fit = modFoY$family$linkinv(fit.link),
#     se.fit = predict(modFoY, ., type = "response", se.fit = T) %>% .$se.fit,
#     lwr3 = modFoY$family$linkinv(fit.link + 3*se.fit.link),
#     upr3 = modFoY$family$linkinv(fit.link - 3*se.fit.link),
#   ) 





##  Step 3 ---- 

predictf = function(modf, dayf, netsLengthf, netsDurationf, scenariof) {
  scenario <- data.frame(
    Year=0,
    DayOfYear=dayf, 
    NetsLength=netsLengthf, 
    NetsDuration=netsDurationf,
    scenario=scenariof,
    CountFoY=0,
    CumCountFoY=0
    #CountFoY2=0,
    #CumCountFoY2=0
  )
  
  for (i in 1:nrow(scenario)){
    scenario$CountFoY[i] =  lapply(modf, function(x) {predict(x, scenario[i,], type = "response")}) %>% unlist() %>% mean()
    
    #scenario$Count2[i] =  lapply(mod, function(x) {predict(x, scenario[i,], type = "response")}) %>% unlist() %>% mean()
    #scenario$CountFoY2[i] = scenario$Count2[i] * predict(modFoY, data.frame(CountOfYear=scenario$CumCountFoY2[i]), type = "response")
    
    if (i<nrow(scenario)){
     # scenario$CumCountFoY2[i+1] = scenario$CountFoY2[i]+scenario$CumCountFoY2[i]
      scenario$CumCountFoY[i+1] = scenario$CountFoY[i]+scenario$CumCountFoY[i]
    }
  }
  scenario
}

bind_pred <- bind_rows(
  predictf(mod, dayf=seq(100,365,10), netsLengthf=156, netsDurationf = 4, scenariof="default"),
  predictf(mod, dayf=seq(1,365,10), netsLengthf=156, netsDurationf = 6, scenariof="6h"),
  predictf(mod, dayf=seq(1,365,10), netsLengthf=200, netsDurationf = 4, scenariof="200m"),
  predictf(mod, dayf=c(seq(1,127,14), seq(130.5,183,7), seq(190,365,14)), netsLengthf=156, netsDurationf = 6, scenario="optimized"),
  predictf(mod, dayf=session2020$DayOfYear, netsLengthf=156, netsDurationf = session2020$NetsDuration
           , scenario="2020"),
)

session %>% ggplot()+ geom_line( aes(group = Year, color = factor(Year), x=DayOfYear, y=CumCountFoY), size=1)                     


p <- bind_pred %>% 
  ggplot()+
  geom_line( aes(group = scenario, color = factor(scenario), x=DayOfYear, y=CumCountFoY), size=1) +
  geom_point( aes(group = scenario, color = factor(scenario), x=DayOfYear, y=CumCountFoY), size=2) +
  geom_line( data = session2020, aes(x=DayOfYear, y=CumCountFoY), size=1) +
  geom_point( data = session2020, aes(x=DayOfYear, y=CumCountFoY), size=2) +
  labs(x='Day of Year', y="Cumulative number of unique RCRC captured") +
  scale_x_continuous(breaks=as.numeric(format(ISOdate(2004,1:12,1),"%j")),
                     labels=format(ISOdate(2004,1:12,1),"%b"),
                     expand = c(0,0),
                     limits = c(100,365)) +
  scale_y_continuous( minor_breaks = c(), expand = c(0,0), limits=c(0,25)) +
  theme(aspect.ratio=9/16, legend.position="top")

ggsave(filename = 'figures/figure4.pdf', plot = p, width = 16, height=9*2, units = "cm")


## Cross validation ----

bind_pred_y = data.frame()
for (y in unique(session$Year)){
  
  mody=list(); i<-0
  for(d in session.imputed){
    i<-i+1
    a = d %>% filter(Year!=y)%>% mutate(Year=factor(Year))
    #mod[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY + WeatherCat + NetsOpen, family=poisson(), data=a)
    mody[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY, family=poisson(), data=a)
    # mod[[i]]  <- gam( CountFoY ~ s(Year, bs="re") + s(DayOfYear) + NetsDuration + NetsLength, family=poisson(), data=a)
    # mod[[i]] <- gamm( CountFoY ~ Year + s(DayOfYear) + NetsDuration + NetsLength + CumCountFoY, random=list(Year=~1), family=poisson(), data = a ) ## Year 
    #
  } 
  
  tmp <- session.imputed[[1]] %>% filter(Year==y)
  bind_pred_y<- bind_rows(
    bind_pred_y,
    predictf(mody, dayf=tmp$DayOfYear, netsLengthf=tmp$NetsLength, netsDurationf = tmp$NetsDuration, scenariof=y)
  )
}

bind_pred_y %>% ggplot()+ geom_line( aes(group = scenario, color = factor(scenario), x=DayOfYear, y=CumCountFoY), size=1)                     

 left_join(
   session %>% group_by(Year) %>% 
     summarise(
       session=max(CumCountFoY)
     ),
   bind_pred_y%>% mutate(Year=scenario) %>% group_by(Year) %>% 
     summarise(
       model=max(CumCountFoY)
     ),
   by="Year") %>% 
  ggplot() + 
  geom_point(aes(x=session,y=model,color=Year)) + 
  geom_abline(slope=1, intercept=0) +
  coord_fixed() +
  labs(x='Actual data', y="Model estimation") +
  scale_x_continuous( minor_breaks = c(), expand = c(0,0), limits = c(0,30)) +
  scale_y_continuous( minor_breaks = c(), expand = c(0,0), limits = c(0,30)) +
  theme(aspect.ratio=1, legend.position="top")

ggsave(filename = 'figures/figureSM8.pdf', plot = print(p), width = 9, height=9, units = "cm")








# Retrival model ----


history <- capture %>% 
  filter(CommonName==specie_name) %>% 
  arrange(Date) %>% 
  group_by(RingNo) %>% 
  mutate(n = 1, 
         retrap_i = cumsum(n)-1, 
         isRetrap = if_else(is.na(lead(retrap_i)>retrap_i),0, 1),
         duration_next_capture = as.numeric(difftime(lead(Date),Date,units='days')),
         duration_last_capture = as.numeric(difftime(last(Date),Date,units='days')),
         nextSeason = last(Year)>Year,
         Yearsince = Year-first(Year),
         isAdult = ifelse(Age==4, TRUE, FALSE),
         isARetrap = first(Year)<Year
         ) %>% 
  select(RingNo, Date, Year, DayOfYear, retrap_i, isRetrap, isARetrap, nextSeason, duration_next_capture, duration_last_capture, isAdult, Yearsince, Weight) %>% 
  arrange(RingNo) 

modr <- gam(history, formula = nextSeason ~ s(DayOfYear) , family="binomial")
modrA <- gam(history %>% filter(isAdult), formula = nextSeason ~ s(DayOfYear), family="binomial")
modrJ <- gam(history %>% filter(!isAdult), formula = nextSeason ~ s(DayOfYear), family="binomial")
modrO <- gam(history %>% filter(retrap_i>0), formula = nextSeason ~ s(DayOfYear), family="binomial")
modrN <- gam(history %>% filter(retrap_i==1), formula = nextSeason ~ s(DayOfYear), family="binomial")

predictmodr <- data.frame(DayOfYear = seq(min(history$DayOfYear),max(history$DayOfYear))) %>%
  mutate(
    r.fit = predict(modr, ., type = "response"),
    r.se.fit = predict(modr, ., type = "response", se.fit = T) %>% .$se.fit,
    rA.fit = predict(modrA, ., type = "response"),
    rA.se.fit = predict(modrA, ., type = "response", se.fit = T) %>% .$se.fit,
    rJ.fit = predict(modrJ, ., type = "response"),
    rJ.se.fit = predict(modrJ, ., type = "response", se.fit = T) %>% .$se.fit,
    ) 



p1 <- ggplot() +
  geom_point( data=history, aes(x=DayOfYear, y=as.numeric(nextSeason), color=isAdult ), size=2) +
  geom_line(data=predictmodr, aes(x=DayOfYear, y=rJ.fit), color = wes_palette('Cavalcanti1')[1], size=1) +
  geom_ribbon(data=predictmodr, aes(x=DayOfYear, ymin = rJ.fit-3*rJ.se.fit, ymax = rJ.fit+3*rJ.se.fit), alpha=0.3, fill = wes_palette('Cavalcanti1')[1]) +
  geom_line(data=predictmodr, aes(x=DayOfYear, y=rA.fit), color = wes_palette('Cavalcanti1')[2], size=1) +
  geom_ribbon(data=predictmodr, aes(x=DayOfYear, ymin = rA.fit-rA.se.fit, ymax = rA.fit+rA.se.fit), alpha=0.3, fill = wes_palette('Cavalcanti1')[2]) +
  geom_line(data=predictmodr, aes(x=DayOfYear, y=r.fit), color = wes_palette('Cavalcanti1')[4], size=2) +
  geom_ribbon(data=predictmodr, aes(x=DayOfYear, ymin = r.fit-r.se.fit, ymax = r.fit+r.se.fit), alpha=0.3, fill = wes_palette('Cavalcanti1')[4]) +
  scale_color_manual( values=wes_palette('Cavalcanti1')) +
  scale_x_continuous(breaks=as.numeric(format(ISOdate(2004,1:12,1),"%j")),
                   labels=format(ISOdate(2004,1:12,1),"%b"),
                   #expand = c(0,0),
                   minor_breaks = c(),
                   limits = c(100,350)) +
  scale_y_continuous(minor_breaks = c(), 
                     #expand = c(0,0),
                     labels = scales::percent) +
  theme(aspect.ratio=9/16, legend.position="none")  + labs(y='Probability of Recapture', color = "Adult", x='Day of Year')

p2 <- session %>% 
  ggplot() +
    geom_point(aes( x=DayOfYear, ifelse(CountAd>2,2,CountAd), size=CountAd) , color=wes_palette('Cavalcanti1')[2]) +
    geom_point(aes( x=DayOfYear, y=ifelse(CountJuv>2,2,CountJuv), size=CountJuv), color=wes_palette('Cavalcanti1')[1]) +
    geom_line(data = predictmod %>% filter(Year %in% 2020), aes(x=DayOfYear, y = fitAd), color=wes_palette('Cavalcanti1')[2], size = 1) +
    geom_line(data = predictmod %>% filter(Year %in% 2020), aes(x=DayOfYear, y = fitJuv), color=wes_palette('Cavalcanti1')[1], size = 1) +
    geom_point(data = dm2020s, aes( x=DayOfYear, y=ifelse(CountJuv>2,2,CountJuv), size=CountJuv),stroke=0, colour=wes_palette('Cavalcanti1')[5])+
    geom_point(data = dm2020s, aes( x=DayOfYear, y=ifelse(CountAd>2,2,CountAd), size=CountAd),stroke=0, colour=wes_palette('Cavalcanti1')[4] )+
    labs(x='Day of Year', y="Count") +
    scale_x_continuous(breaks=as.numeric(format(ISOdate(2004,1:12,1),"%j")),
                       labels=format(ISOdate(2004,1:12,1),"%b"),
                       minor_breaks = c(),
                       #expand = c(0,0),
                       limits = c(100,365)
                      )+
    scale_y_continuous(limits = c(0,2), 
                       #expand = c(0,0),
                       minor_breaks = c())+
    theme(aspect.ratio=9/16, legend.position="none")
  
p <- arrangeGrob(p1, p2)

subplot(ggplotly(p1, width=wid, height = hei*2), ggplotly(p2, width=wid, height = hei*2), shareX=T, nrows=2)
