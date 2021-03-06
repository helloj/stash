async  = require 'async'
redis  = require 'redis'
_      = require 'underscore'

noop = () ->

DEFAULTS =
	host: 'localhost'
	port: 6379

class Stash
	
	constructor: (config) ->
		@config = _.extend DEFAULTS, config
		@redis  = redis.createClient @config.port, @config.host
	
	quit: (force = false) ->
		if force then @redis.end()
		else @redis.quit()
	
	get: (key, callback) ->
		@redis.get key, (err, data) =>
			if err? then return callback(err)
			callback null, @_unpack(data)
	
	set: (key, value, callback = noop) ->
		@redis.set key, @_pack(value), callback
	
	inv: (args...) ->
		callback = if _.isFunction _.last args then args.pop() else noop
		@_walk _.flatten(args), (err, graph) =>
			@redis.del graph.nodes, (err) =>
				if err? then return callback(err)
				callback null, graph.nodes
	
	rem: (args...) ->
		callback = if _.isFunction _.last args then args.pop() else noop
		keys = _.flatten args
		@inv keys, (err) =>
			if err? then return callback(err)
			async.forEach keys, _.bind(@drem, this), (err) =>
				if err? then return callback(err)
				@redis.del keys, (err) =>
					if err? then return callback(err)
					callback null, keys
	
	dget: (keys..., callback) ->
		keys = _.flatten keys
		getEdges = (key, next) =>
			async.parallel {
				in:  (done) => @redis.smembers @_inkey(key),  done
				out: (done) => @redis.smembers @_outkey(key), done
			}, next
		if keys.length == 1
			getEdges keys[0], callback
		else
			async.map keys, getEdges, (err, results) ->
				if err? then return callback(err)
				reducer = (deps, result, index) ->
					deps[keys[index]] = result
					deps
				callback null, _.reduce results, reducer, {}
	
	dset: (args...) ->
		callback = if _.isFunction _.last args then args.pop() else noop
		child    = args.shift()
		parents  = _.flatten(args)
		@dget child, (err, deps) =>
			if err? then return callback(err)
			async.parallel {
				added:   (done) => @dadd child, _.difference(parents, deps.in), done
				removed: (done) => @drem child, _.difference(deps.in, parents), done
			}, callback
	
	dadd: (args...) ->
		callback = if _.isFunction _.last args then args.pop() else noop
		child    = args.shift()
		parents  = _.flatten(args)
		addEdges = (parent, next) =>
			async.parallel [
				(done) => @redis.sadd @_outkey(parent), child, done
				(done) => @redis.sadd @_inkey(child), parent, done
			], next
		async.forEach parents, addEdges, (err) =>
			if err? then return callback(err)
			callback(null, parents)
	
	drem: (args...) ->
		callback = if _.isFunction _.last args then args.pop() else noop
		child    = args.shift()
		if args.length > 0
			# Remove a subset of parent nodes
			parents = _.flatten(args)
			removeEdges = (parent, next) =>
				async.parallel [
					(done) => @redis.srem @_outkey(parent), child, done
					(done) => @redis.srem @_inkey(child), parent, done
				], next
			async.forEach parents, removeEdges, (err) =>
				if err? then return callback(err)
				callback(null, parents)
		else
			# Remove all parent nodes
			@dget child, (err, deps) =>
				if err? then return callback(err)
				parents = deps.in
				removeEdge = (parent, next) =>
					@redis.srem @_outkey(parent), child, next
				async.forEach parents, removeEdge, (err) =>
					if err? then return callback(err)
					@redis.del @_inkey(child), (err) =>
						if err? then return callback(err)
						callback(null, parents)
	
	_walk: (keys, callback) ->
		graph =
			nodes: keys
			edges: []
			depth: 0
		remaining = _.map keys, @_outkey
		moreleft  = -> remaining.length > 0
		collect   = (next) =>
			@redis.sunion remaining, (err, deps) =>
				graph.edges = _.union graph.edges, remaining
				graph.depth++
				unless err?
					graph.nodes = _.union graph.nodes, deps
					remaining   = _.difference _.map(deps, @_outkey), graph.edges
				next()
		async.whilst moreleft, collect, (err) ->
			if err? then return callback(err)
			callback(null, graph)
	
	_inkey:    (key)  -> "stash:#{key}:in"
	_outkey:   (key)  -> "stash:#{key}:out"
	_pack:     (obj)  -> if _.isString(obj) then obj else JSON.stringify(obj)
	_unpack:   (data) -> JSON.parse(data)
	
module.exports = Stash
