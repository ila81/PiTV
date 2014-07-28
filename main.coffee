bodyParser = require 'body-parser'
methodOverride = require 'method-override'
omx = require 'omxcontrol'
readTorrent = require 'read-torrent'
peerflix = require 'peerflix'
uuid = require 'node-uuid'
path = require 'path'
http = require 'http'
urltool = require 'url'
tpb = require 'thepiratebay'
fs = require 'fs'
moviedb = require('moviedb')('c2c73ebd1e25cbc29cf61158c04ad78a')
tempDir = require('os').tmpdir()
express = require 'express'
app = express()
server = http.Server(app)
io = require('socket.io')(server)
torrentStream = null
statePlaying = false

server.listen 80

request = (url, cb) ->
  obj = urltool.parse url
  options =
    host: obj.host
    path: obj.path
    method: 'GET'
  req = http.request options, (res) ->
    str = ''
    if res.statusCode isnt 200
      cb(true, null, null)
    res.on 'data', (chunk) ->
      str += chunk;
    res.on 'end', () ->
      cb(null, null, str)
  req.on 'error', (e) ->
    cb(e, null, null)
  req.write 'data\n'
  req.write 'data\n'
  req.end()

createTempFilename = ->
  path.join tempDir, 'torrentcast_' + uuid.v4()

clearTempFiles = ->
  fs.readdir tempDir, (err, files) ->
    unless err
      files.forEach (file) ->
        if file.substr 0, 11 is 'torrentcast'
          fs.rmdir path.join tempDir, file

app.use bodyParser.urlencoded
  extended: true
app.use bodyParser.json()
app.use methodOverride()

app.set 'view engine', 'ejs'
app.set 'views', (__dirname + '/views')

app.use '/static', express.static(__dirname + '/static')

app.get '/', (req, res, next) ->
  res.render 'remote.ejs'

app.get '/tv', (req, res, next) ->
  res.render 'tv.ejs'

tv = io.of '/iotv'
tv.on 'connection', (socket) ->
  console.log "TV Connected!"

remote = io.of '/ioremote'
remote.on 'connection', (socket) ->
  socket.on 'forwardMedia', () ->
    if statePlaying
      omx.forward()
  socket.on 'backwardMedia', () ->
    if statePlaying
      omx.backward()
  socket.on 'stopMedia', () ->
    if torrentStream
      torrentStream.destroy()
      torrentStream = null
    statePlaying = false
    tv.emit 'main'
    omx.quit()
  socket.on 'pauseplayMedia', () ->
    if statePlaying
      statePlaying = false
      if torrentStream
        torrentStream.swarm.pause()
    else
      statePlaying = true
      if torrentStream
        torrentStream.swarm.resume()
    omx.pause()
  socket.on 'searchEpisodeTorrents', (string, fn) ->
    tpb.search string,
      category: '205'
    , (err, results) ->
      if err
        fn
          success: false
          error: 'No torrents found!'
      else
        fn
          success: true
          torrents: results
  socket.on 'searchMovieTorrents', (imdbid, fn) ->
    url = 'http://yts.re/api/listimdb.json?imdb_id=' + imdbid
    request url, (err, res, body) ->
      if err
        url = 'http://yts.im/api/listimdb.json?imdb_id=' + imdbid
        request url, (err, res, body) ->
          if err
            fn
              success: false
              error: 'Could not retrieve a list of torrents!'
          else
            result = JSON.parse body
            if result.MovieCount == 0
              fn
                success: false
                error: 'No torrents found!'
            else
              fn
                success: true
                torrents: result.MovieList
      else
        result = JSON.parse body
        if result.MovieCount == 0
          fn
            success: false
            error: 'No torrents found!'
        else
          fn
            success: true
            torrents: result.MovieList
  socket.on 'getMovie', (id, fn) ->
    moviedb.movieInfo
      id: id
    , (err, res) ->
      if err
        fn
          success: false
          error: 'Could not retrieve the movie!'
      else
        fn
          success: true
          movie: res
  socket.on 'getSerie', (id, fn) ->
    url = 'http://eztvapi.re/show/' + id
    request url, (err, res, body) ->
      if err
        fn
          success: false
          error: 'Could not retrieve serie!'
      else
        try
          result = JSON.parse body
          fn
            success: true
            serie: result
        catch
          fn
            success: false
            error: 'Could not retrieve serie!'
  socket.on 'getPopularSeries', (page, fn) ->
    url = 'http://eztvapi.re/shows/' + page
    request url, (err, res, body) ->
      if err
        fn
          success: false
          error: 'Could not retrieve series!'
      else
        result = JSON.parse body
        fn
          success: true
          series: result
  socket.on 'getPopularMovies', (page, fn) ->
    moviedb.miscPopularMovies
      page: page
    ,(err, res) ->
      if err
        fn
          success: false
          error: 'Could not retrieve any movies!'
      else
        fn
          success: true
          movies: res.results
  socket.on 'searchSeries', (data, fn) ->
    query = encodeURIComponent(data.query).replace('%20', '+')
    url = 'http://eztvapi.re/shows/' + data.page + '?keywords=' + query
    request url, (err, res, body) ->
      if err
        fn
          success: false
          error: 'Could not retrieve series!'
      else
        try
          result = JSON.parse body
          fn
            success: true
            series: result
        catch
          fn
            success: false
            error: 'Could not retrieve series!'
  socket.on 'searchMovies', (data, fn) ->
    moviedb.searchMovie
      page: data.page
      query: data.query
      search_type: 'ngram'
    ,(err, res) ->
      if err
        fn
          success: false
          error: 'Could not retrieve any movies!'
      else
        fn
          success: true
          movies: res.results
  socket.on 'playTorrent', (magnet, fn) ->
    tv.emit 'loading'
    if magnet? and magnet.length > 0
      readTorrent magnet, (err, torrent) ->
        if err
          tv.emit 'main'
          fn
            success: false
            error: 'Failure while parsing the magnet link!'
        else
          if torrentStream
            torrentStream.destroy()
          torrentStream = null
          clearTempFiles()

          torrentStream = peerflix torrent,
            connections: 100
            path: createTempFilename()
            buffer: (1.5 * 1024 * 1024).toString()

          torrentStream.server.on 'listening', ->
            port = torrentStream.server.address().port
            statePlaying = true
            omx.start 'http://127.0.0.1:' + port + '/'
            tv.emit 'black'
          fn
            success: true
    else
      tv.emit 'main'
      fn
        success: false
        error: 'No magnet link received!'
