# Configuration
config    = require '../config'

# Packages
express      = require 'express'
compression  = require 'compression'
errorHandler = require 'errorhandler'
logger       = require 'morgan'
yaml         = require 'js-yaml'
qs           = require 'qs'

# Modules
blueprint = require '../blueprint'

# Logging
log       = require('../logging').get 'app/controllers/api'


# Constants
DEVELOPMENT_MODE  = process.env.NODE_ENV is 'development'
BUFFER_LIMIT      = parseInt(process.env.BUFFER_LIMIT, 10)
ORIGIN_REGEXP     = new RegExp "#{process.env.DOMAIN}".replace(/[\-{}\[\]+?.,\\\^$|#\s]/g, '\\$&') + "$"
APIARY_REGEXP     = new RegExp /apiary\.io$/
DEVELOP_REGEXP    = new RegExp /apiblueprint\.dev:([\d]{1,})$/


# Local functions
normalizeNewlines = (s) ->
  s.replace(/\r\n/g, "\n").replace(/\r/g, "\n")


formatTime = (hrtime) ->
  # nano (1/1000) => micro (1/1000000) => ms
  hrtime[0] + ' s, ' + (hrtime[1] / 1000000).toFixed(0) + ' ms'


addCORS = (req, res, next) ->
  res.set 'Access-Control-Allow-Credentials', 'true'
  res.set 'Access-Control-Allow-Methods', 'POST, GET'
  res.set 'Access-Control-Allow-Headers', 'Content-Type, Accept'
  res.set 'Access-Control-Expose-Headers', 'Content-Type, Accept'
  res.set 'Access-Control-Max-Age', 60 * 60 * 24

  origin = req.get('Origin') or ''
  if ORIGIN_REGEXP.test(origin) or APIARY_REGEXP.test(origin) or DEVELOP_REGEXP.test(origin)
    res.set 'Access-Control-Allow-Origin', origin
  else
    res.set 'Access-Control-Allow-Origin', process.env.DOMAIN

  next()


bodyParser = (req, res, next) ->
  req.setEncoding 'utf8'
  req.body = ''
  req.on 'data', (chunk) ->
    req.body += chunk
  req.on 'end', ->
    next()


# Setup
exports.setup = (app) ->
  app.set 'trust proxy', true  # trust headers like X-Forwarded-* for setting req.proto et al
  app.use compression(threshold: 512)

  # Setup development error handler.
  # Modify `NODE_ENV` environment variable to force the right scope.
  if DEVELOPMENT_MODE
    app.use errorHandler
      dumpExceptions: true
      showStack: true
      fileUrls: 'txmt'
  else
    app.use logger 'tiny'


  app.options '/parser', addCORS, (req, res) ->
    res.send ''

  app.post '/parser', addCORS, bodyParser, (req, res) ->
    if not req.body
      # FIXME snowcrash/parseresult has special code for this, so we should return
      # proper result with a proper error code or let it to protagonist completely
      res.json 400,
        message: 'No blueprint code, nothing to parse.'
    else
      blueprintCode = normalizeNewlines req.body

      t = process.hrtime()
      blueprint.parse blueprintCode, (err, result) ->
        result.error ?= err or null
        result._version = '1.0'
        res.set 'X-Parser-Time', formatTime process.hrtime t
        res.statusCode = if result.error and result.error.code isnt 0 then 400 else 200

        if req.accepts 'application/vnd.apiblueprint.parseresult.raw+yaml'
          res.set 'Content-Type', 'application/vnd.apiblueprint.parseresult.raw+yaml; version=1.0'
          body = yaml.safeDump JSON.parse JSON.stringify result  # https://github.com/nodeca/js-yaml/issues/132
        else
          res.set 'Content-Type', 'application/vnd.apiblueprint.parseresult.raw+json; version=1.0'
          body = JSON.stringify result

        res.send new Buffer body  # sending without charset parameter


  app.options '/composer', addCORS, (req, res) ->
    res.send ''

  app.post '/composer', addCORS, bodyParser, (req, res) ->
    if not req.body
      res.json 400,
        message: 'No AST, nothing to compose.'
    else
      format = if req.is 'application/vnd.apiblueprint.ast.raw+yaml' then 'yaml' else 'json'
      ast = normalizeNewlines req.body

      t = process.hrtime()
      blueprint.compose ast, format, (err, blueprintCode) ->
        res.set 'X-Composer-Time', formatTime process.hrtime t

        if err
          if err instanceof blueprint.MatterCompilerError
            res.json 500,
              message: 'Internal server error.'
          else
            res.json 400,
              message: err.message
        else
          res.set 'Content-Type', 'text/vnd.apiblueprint+markdown; version=1A'
          res.send blueprintCode  # sending with charset=utf-8


  app.get '/', (req, res) ->
    res.set 'Content-Type', 'application/hal+json'
    res.set 'Link', '<http://docs.apiblueprintapi.apiary.io>; rel="profile"'
    res.send 200, new Buffer JSON.stringify
      _links:
        self: {href: '/'}
        parse: {href: '/parser'}
        compose: {href: '/composer'}


  # Setup production error handler returning JSON.
  # Modify `NODE_ENV` environment variable to force the right scope.
  if not DEVELOPMENT_MODE
    app.use (err, req, res, next) ->
      res.json 500,
        message: 'Internal server error.'
        description: err.message

  # HTTP 404 error handler. We're not serving any static files,
  # so this is okay.
  app.get '*', (req, res) ->
    res.json 404,
      message: 'Specified resource was not found.'
