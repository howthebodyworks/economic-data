# Two granger libraries - we use the latter because it has missing value handling baked in,
# though the former is better for vectorised correlations
# Note that neither support true multivariate calculations, just pairwise.
#library("MSBVAR")
library("lmtest")
#library("ggplot2")
library("reshape2")
#library("ggdendro")
library("RSQLite")

# example usage:
# favourite.equities = get.favourite.equities(limit=Inf)
# #equities.m = pairwise.granger.test.m(favourite.equities)
# relations.1 = pairwise.granger.test(favourite.equities, 1)
# relations.2 = pairwise.granger.test(favourite.equities, 2)
# relations.3 = pairwise.granger.test(favourite.equities, 3)
# relations.all=rbind(relations.1,relations.2,relations.3)
# put.state()
# correlations.to.sql(relations.all)


favourite.equity.tickers = c('AAI', 'AAT', 'AAU', 'AAY',
  'AEF', 'AGK', 'AIZ', 'ALL', 'AMP', 'ANN', 'ANZ', 'APD', 'APN', 'APP',
  'AQF', 'ARG', 'ASX', 'AVH', 'BBG', 'BEN', 'BGA', 'BHP', 'BKL', 'BOQ',
  'BXB', 'CBA', 'CCL', 'CCV', 'CER', 'CLO', 'CLX', 'CMJ', 'CNG', 'CRF',
  'CSR', 'CTY', 'CWN', 'CYU', 'DJS', 'DMP', 'EAU', 'ELD', 'FLT', 'FMG',
  'FPA', 'FPH', 'FXJ', 'GDA', 'GEM', 'GFF', 'GMG', 'HRL', 'HVN', 'IFL',
  'IFM', 'ION', 'JBH', 'JET', 'KMD', 'LCT', 'LMW', 'MGI', 'MGM', 'MGR',
  'MIX', 'MQG', 'MUE', 'MXU', 'MYR', 'NAB', 'NCM', 'NVT', 'NWS', 'OEC',
  'OMI', 'ORD', 'ORG', 'ORI', 'OST', 'PBG', 'PHG', 'PNW', 'QAN', 'QBE',
  'QRN', 'RRS', 'RUM', 'SBK', 'SGH', 'SGP', 'SGT', 'SIP', 'SKC', 'SKT',
  'SOL', 'SUN', 'SWM', 'SXL', 'SYD', 'TAH', 'TEL', 'TEN', 'TIS', 'TLS',
  'TPC', 'TRS', 'TSE', 'TTS', 'VEI', 'VEL', 'VRL', 'VSC', 'VTG', 'WBC',
  'WDC', 'WEB', 'WES', 'WFA', 'WFT', 'WOW', 'WRT', 'WSF', 'WTF', 'WWM',
  'ZBI', 'ZRI')

base.path = '/Users/dan/Dropbox/trade_data'
csv.cache.path = paste(base.path, "csvcache", sep="/")
r.state.path = paste(base.path, "Rstate", sep="/")

get.state = function() {
  load.image(paste(r.state.path,"RData", sep="/"))
}

put.state = function() {
  save.image(paste(r.state.path,"RData", sep="/"))
}

get.equities = function (limit=Inf, limit.to=NA) {
  files = list.files(csv.cache.path, pattern=".*\\.csv\\.gz")
  i=0

  equities = NULL;

  for (file.name in files) {
    ticker.name = substr(file.name, 1, 3)
  
    if(!is.na(limit.to) && !(ticker.name %in% limit.to)) {next}
    if(i>limit) {break}
    
    i=i+1
      
    one.equity = read.csv(gzfile(paste(csv.cache.path, file.name, sep = "/")))
    trimmed.equity = one.equity[c("Date")]
    # take max because some shares still trade at 0
    # (granularity is $0.01, zero is -4.61)
    trimmed.equity[ticker.name] = log(pmax(
      one.equity["Adj.Close"],
      0.005))

    if(is.null(equities)) {
      equities = trimmed.equity
    } else {
      equities = merge(equities, trimmed.equity, all.x=TRUE, all.y=TRUE)
    }
  }
  equities$Date = as.Date(equities$Date)
  return(equities)
}
get.favourite.equities = function (limit=Inf) {
  return(get.equities(limit=limit, favourite.equity.tickers))
}


# This looks like it should go formula style.
# grangertest(AAT ~ AAY, data=equities)
# but constructing formulae in code is tedious,
# so we pass time series directly

get.ts = function(equities, ticker.name) {
  return(zoo(equities[,ticker.name], equities$Date))
}

granger.fp = function(xname, yname, data, k=1){
  res = NULL
  error = try(res <- grangertest(data[,xname], data[,yname], order=k))
  if(is.null(res)) return(list(f=NA,p=NA,worked=FALSE))
  f = res[2, "F"]
  p = res[2, "Pr(>F)"]
  return(list(f=f, p=p, worked=TRUE))
}
vec.granger.fp = Vectorize(granger.fp, vectorize.args=c('xname', 'yname'))

granger.p = function(xname, yname, data, k=1){
  return(as.numeric(granger.fp(xname, yname, data, k)['p']))
}
vec.granger.p = Vectorize(granger.p, vectorize.args=c('xname', 'yname'))

granger.f = function(xname, yname, data, k=1){
  return(as.numeric(granger.fp(xname, yname, data, k)['f']))
}
vec.granger.f = Vectorize(granger.f, vectorize.args=c('xname', 'yname'))

# returns a "melted" pairwise granger-causality distance frame
#Need to cast this to and from p/f matrices
#try:
# http://stackoverflow.com/a/9617424
# http://tolstoy.newcastle.edu.au/R/e6/help/09/01/0598.html
pairwise.granger.test = function(equities, k=1) {
  equity.names = names(equities)[-1]
  n = length(equity.names)
  n.pairs = n*(n-1)
  relations = data.frame
  sources = vector(mode='character', length = n.pairs)
  targets = vector(mode='character', length = n.pairs)
  fs = vector(mode='numeric', length = n.pairs)
  ps = vector(mode='numeric', length = n.pairs)

  i = 0
  for(x in 1:n) {
    for(y in (1:n)[-x]) {
      source.name = equity.names[x]
      target.name = equity.names[y]
      print(c(source.name, target.name))
      res = granger.fp(source.name, target.name, equities, k)
      i = i+1
      sources[i] = source.name
      targets[i] = target.name
      fs[i] = res$f
      ps[i] = res$p
    }
  }
  #store the order of the correlation as well
  ks = rep(k, length(fs))
  return(data.frame(source=as.factor(sources), target=as.factor(targets),
                    f=fs, p=ps, k=ks))
}

# returns a pairwise granger-causality distance matrix
# Need to cast this to and from sparse p/f frames
pairwise.granger.test.m = function(equities, k=1) {
  x = names(equities)[-1]
  names(x) = x
  y = x
  return(outer(x, y, vec.granger.f, equities))
}

# To see how to do this, try...
#  Traditional:
#    http://flowingdata.com/2010/01/21/how-to-make-a-heatmap-a-quick-and-easy-solution/
#    http://sphaerula.com/legacy/R/correlationPlot.html
#    http://www.phaget4.org/R/image_matrix.html
#  ggplot2:
#    https://learnr.wordpress.com/2010/01/26/ggplot2-quick-heatmap-plotting/
#    http://stackoverflow.com/a/5554352
#    http://stackoverflow.com/a/6675983 (bonus dendrogram!)
#    http://hosho.ees.hokudai.ac.jp/~kubo/Rdoc/library/ggmap/html/ggimage.html
#  general community structure:
#    http://sieste.wordpress.com/2012/05/21/inferring-the-community-structure-of-networks/
#    http://cran.cnr.berkeley.edu/web/views/Cluster.html
#
# linkcomm seems to do this for weighted digraphs.
# agnes (from cluster) doesn't like missing values, hclust (from stats)
#    might be OK with 'em, but it isn't clear
# Here is an R GEXF gephi exporter (although a CSV export will probably do
#   the trick)
# Drew conway chatter on the issue: http://www.drewconway.com/zia/?p=1221
# For a combo version, use the r heatmap plot with bonus dendrogram
#   heatmap(favourite.pairwise.vals)
#   more general clustering is in PDM, cluster, et al
# Sorting each axis separately might be informative enough without getting
#   overexcited about directed graphs. 
# Probably it can all go into SQL anyway

plot.correlation.matrix = function(correlations){
  
}

# For SQL, gephi likes nodes and edges in separate tables - 
# Edges:
# "source", "target", "label", "weight"
# Nodes:
# "id", "label", "x, "y", "size"
# For both of these we can add "start" and "end" to dynamic graphs
# here we respect the "source", "target" and "id" names but will use
# SELECT AS to coerce the remainder

# Convert a sparse pairwise correlation frame into a weighted, directed,
# SQL graph
# Gephi can interpret this using the following nodes/edges queries
# respectively
# SELECT id, id AS "label" FROM nodes
# SELECT source, target, f AS "weight" FROM edges WHERE p<0.05 AND k=2
# (Substitute your favourite p, k values)
correlations.to.sql = function(data, dbname="equities_graph.db", max.p=1.0) {
  dbpath = paste(base.path, dbname, sep="/")
  print(c("opening", dbpath))
  conn <- dbConnect("SQLite", dbname = dbpath)
  
  data = data[!is.na(data$f),]
  data = data[data$p<max.p,]
  node.names = data.frame(id=unique(data$source))
  
  dbWriteTable(conn, "nodes", node.names)
  dbWriteTable(conn, "edges", data)
  dbDisconnect(conn)
}

# Convert a weighted, directed, SQL graph into a sparse pairwise
# correlation frame
sql.to.correlations = function(dbname="equities_graph.db",
      q = "SELECT * from edges") {
  dbpath = paste(base.path, dbname, sep="/")
  print(c("opening", dbpath))
  conn <- dbConnect("SQLite", dbname = dbpath)
  res = dbGetQuery(conn, q)
  dbDisconnect(conn)
  return(res)
}