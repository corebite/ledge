module("ledge", package.seeall)


-- Ledge
--
-- This module is loaded once for the first request, and so 
local ledge = {
	_config_file = require("config"),
	config = {},
	cache = {},
	
	redis = {
		parser = require("redis.parser"),
	},
	
	-- Subrequest locations
	locations = {
		origin = "/__ledge/origin",
		wait_for_origin = "/__ledge/wait_for_origin",
		redis = "/__ledge/redis"
	},
	
	-- Constants
	SUBZERO 	= 'Sub-Zero',
	COLD 		= 'Cold',
	WARM 		= 'Warm',
	HOT 		= 'Hot',
	FETCHED		= 'Fetched',
	COLLAPSED 	= 'Collapsed',
	ABSTAINED	= 'Abstained',
}



-- Loads runtime configuration into ledge.config
--
-- The configuration file is only loaded once for the first request. 
-- This runs any dynamatic pattern matches for the current request.
--
-- @return void
function ledge.process_config()
	for k,v in pairs(ledge._config_file) do
		-- Grab the default
		ledge.config[k] = ledge._config_file[k].default
		
		-- URI matches
		if ledge._config_file[k].match_uri then
			for i,v in ipairs(ledge._config_file[k].match_uri) do
				if (ngx.var.uri:find(v[1]) ~= nil) then
					ledge.config[k] = v[2]
					break -- We take the first hit
				end
			end
		end
		
		-- Request header matches
		if ledge._config_file[k].match_header then
			local h = ngx.req.get_headers()
			
			for i,v in ipairs(ledge._config_file[k].match_header) do
				if (h[v[1]] ~= nil) and (h[v[1]]:find(v[2]) ~= nil) then
					ledge.config[k] = v[3]
					break
				end
			end
		end
	end

	ngx.log(ngx.NOTICE, "ledge.config.max_stale_age: " .. tostring(ledge.config.max_stale_age))
	ngx.log(ngx.NOTICE, "ledge.config.collapse_origin_requests: " .. tostring(ledge.config.collapse_origin_requests))
	ngx.log(ngx.NOTICE, "ledge.config.process_esi: " .. tostring(ledge.config.process_esi))
end


function ledge.prepare(uri)
	
	local res = ledge.cache.read(uri)
	if (res) then
		if (res.ttl - ledge.config.max_stale_age <= 0) then
			res.type = ledge.WARM
		else
			res.type = ledge.HOT
		end
	else
		res = { type = ledge.SUBZERO }
	end
	
	return res
end


function ledge.send(response)
	local ledge_header = response.type
	if response.action then
		ledge_header = ledge_header .. "; " .. response.action
	end
	
	ngx.status = response.status
	for k,v in pairs(response.header) do
		ngx.header[k] = v
	end
	ngx.header['X-Ledge'] = ledge_header
	ngx.print(response.body)
	ngx.eof()
end



-- Runs a single query and returns the parsed response
--
-- e.g. local res = ledge.redis.query({ 'HGET', 'mykey' })
--
-- @param	table	query expressed as a list of Redis commands
-- @return	mixed	Redis response or false on failure
function ledge.redis.query(query)
	local res = ngx.location.capture(ledge.locations.redis, {
		method = ngx.HTTP_POST,
		args = { n = 1 },
		body = ledge.redis.parser.build_query(query)
	})
	
	if (res.status == ngx.HTTP_OK) then
		return ledge.redis.parser.parse_reply(res.body)
	else
		return false
	end
end


-- Runs multiple queries pipelined. This is faster than parallel subrequests
-- it seems.
--
-- e.g. local resps = ledge.redis.query_pipeline({ q1, q2 })
--
-- @param	table	A table of queries, where each query is expressed as a table
-- @return	mixed	A table of parsed replies, or false on failure
function ledge.redis.query_pipeline(queries)
	for i,q in ipairs(queries) do
		queries[i] = ledge.redis.parser.build_query(q)
	end
	
	local rep = ngx.location.capture(ledge.locations.redis, {
		args = { n = #queries },
		method = ngx.HTTP_POST,
		body = table.concat(queries)
	})
	
	local reps = {}
	
	if (rep.status == ngx.HTTP_OK) then
		local results = ledge.redis.parser.parse_replies(rep.body, #queries)
		for i,v in ipairs(results) do
			table.insert(reps, v[1]) -- #1 = res, #2 = typ
		end
		return reps
	else
		return false
	end
end


-- Reads an item from cache
--
-- @param	string			The URI (cache key)
-- @return	bool | table	Success/failure | The response table
function ledge.cache.read(uri)
	
	-- Fetch from Redis
	local rep = ledge.redis.query_pipeline({
		{ 'HMGET', uri.key, 'status', 'body' },	-- Main content
		{ 'HGETALL', uri.header_key },			-- Headers
		{ 'TTL', uri.key }						-- TTL
	})
	
	if (r ~= false) then
		local b = rep[1]
		local h = rep[2]
		local t = tonumber(rep[3])
	
		if t > -1 then -- we got something valid
			
			-- Reassemble a response object
			local response = { -- Main parts will be ordered as per the HMGET args
				status = b[1],
				body = b[2],
				header = {},
				ttl = t,
			}

			-- Whereas header parts will be a flat list of pairs..
			for i = 1, #h, 2 do
				response.header[h[i]] = h[i + 1]
			end

			return response
		else 
			return nil
		end
	else 
		ngx.log(ngx.ERROR, "Failed to read from Redis")
		return nil
	end
end


-- Stores an item in cache
--
-- @param	uri			The URI (cache key)
-- @param	response	The HTTP response object to store
-- @return	boolean
function ledge.cache.save(uri, response)
	-- TODO: Work out if we're allowed to save
	-- We could store headers even if its no-store, so that we know the policy
	-- for this item. Next hit is a cache hit, but reads the headers, and finds 
	-- it has to go fetch anyway (and store, in case the policy changed)
	--
	-- This might allow for collapse forwaring to be on, but only used by known cacheable content?
	--
	-- On first request (so we know nothing), concurrent requests get told to wait, 
	-- as if they will get the shared hit, and if it's no-store, told
	-- to fetch in the end. But that will only happen once per URI. Potential flood I guess.
	
	-- Store the response. Header is a foreign key to another hash.
	local q = { 
		'HMSET', uri.key, 
		'body', response.body, 
		'status', response.status,
		'header', uri.header_key
	}
	
	-- Store the headers
	local header_q = { 'HMSET', uri.header_key } 
	for k,v in pairs(response.header) do -- Add each k,v as a pair
		table.insert(header_q, string.lower(k))
		table.insert(header_q, v)
	end
	
	-- Work out TTL
	local ttl = ledge.calculate_expiry(response.header)
	local expire_q = { 'EXPIRE', uri.key, ttl }
	local expire_hq = { 'EXPIRE', uri.header_key, ttl }

	local res = ledge.redis.query_pipeline({ q, header_q, expire_q, expire_hq })
	-- TODO: Should probably return something.

end


-- Fetches a resource from the origin server.
--
-- @param	table	The URI table
-- @return	table	Response
function ledge.fetch(uri, res)
	
	if (ledge.config.collapse_origin_requests == false) then
		local origin = ngx.location.capture(ledge.locations.origin .. uri.uri);
		ledge.cache.save(uri, origin)
		
		res.status = origin.status
		res.body = origin.body
		res.header = origin.header
		res.action = ledge.FETCHED
		return res
	else
	
		-- Set the fetch key
		local fetch = ledge.redis.query({ 'SETNX', uri.fetch_key, '1' })
		-- TODO: Read from config
		ledge.redis.query({ 'EXPIRE', uri.fetch_key, '10' })
		if (fetch == 1) then -- Go do the fetch
			local origin = ngx.location.capture(ledge.locations.origin .. uri.uri);
			ledge.cache.save(uri, origin)
			
			-- Remove the fetch and publish to waiting threads
			ledge.redis.query({ 'DEL', uri.fetch_key })
			ledge.redis.query({ 'PUBLISH', uri.key, 'finished'})
			
			res.status = origin.status
			res.body = origin.body
			res.header = origin.header
			res.action = ledge.FETCHED
			return res
		else
			-- This fetch is already happening 
			if (res.type < ledge.WARM) then
				-- Go to the collapser proxy
				local rep = ngx.location.capture(ledge.locations.wait_for_origin, {
					args = { channel = uri.key }
				});
			
				if (rep.status == ngx.HTTP_OK) then				
					local results = ledge.redis.parser.parse_replies(rep.body, 2)
					local messages = results[2][1] -- Second reply, body
				
					for k,v in pairs(messages) do
						if (v == 'finished') then
							
							ngx.log(ngx.NOTICE, "FINISHED WAITING")
							
							-- Go get from redis
							local cache = ledge.cache.read(uri)
							res.status = cache.status
							res.body = cache.body
							res.header = cache.header
							res.action = ledge.COLLAPSED
							return res
							
						end
					end
				else
					return nil, rep.status -- Pass on the failure
				end
			else -- Is WARM and already happening, so bail
				res.action = ledge.ABSTAIN
				return res
			end
		end
	end
end

-- TODO: Work out the valid expiry from headers, based on RFC.
function ledge.calculate_expiry(header)
	return 15 + ledge.config.max_stale_age
end

return ledge