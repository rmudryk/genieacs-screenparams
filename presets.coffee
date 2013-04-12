config = require './config'
common = require './common'
db = require './db'
mongoQuery = require './mongo-query'
query = require './query'


getPresets = (callback) ->
  db.memcached.get('presets', (err, res) ->
    if res
      callback(res)
      return

    db.presetsCollection.find().toArray((err, presets) ->
      throw new Error(err) if err

      db.memcached.set('presets', presets, config.PRESETS_CACHE_DURATION)
      callback(presets)
    )
  )


getPresetsHash = (callback) ->
  db.memcached('presets_hash', (err, res) ->
    if res
      callback(res)
    else
      getPresets((presets) ->
        hash = callback(calculatePresetsHash(presets))
        db.memcached.set('presets_hash', hash, config.PRESETS_CACHE_DURATION, (err, res) ->
          callback(hash)
        )
      )
  )


calculatePresetsHash = (presets) ->
  crypto = require('crypto')
  hash = crypto.createHash('md5').update(JSON.stringify(presets)).digest('hex')
  return hash


exports.assertPresets = (deviceId, presetsHash, callback) ->
  getPresets((presets) ->
    # only fetch relevant params
    projection = {}
    for p in presets
      p.precondition = query.expand(p.precondition)
      mongoQuery.projection(p.precondition, projection)

      for c in p.configurations
        switch c.type
          when 'value', 'age'
            projection[c.name] = 1
          when 'firmware'
            projection['InternetGatewayDevice.DeviceInfo.SoftwareVersion'] = 1
          else
            throw new Error('Unknown configuration type')

    db.devicesCollection.findOne({'_id' : deviceId}, projection, (err, device) ->
      devicePresets = []
      for p in presets
        if mongoQuery.test(device, p.precondition)
          devicePresets.push(p)

      configurations = accumulateConfigurations(devicePresets)
      now = Date.now()
      taskList = []
      expiry = config.PRESETS_CACHE_DURATION
      getParameterValues = []
      setParameterValues = []
      for c in configurations
        param = common.getParamValueFromPath(device, c.name)
        continue if not param? # ignore parameters that don't exist

        switch c.type
          when 'value'
            dst = common.matchType(param._value, c.value)
            if param._value != dst
              setParameterValues.push([c.name, dst, param._type])
          when 'age'
            timeDiff = (now - param._timestamp) / 1000
            if (c.age - timeDiff < config.PRESETS_TIME_PADDING)
              expiry = Math.min(expiry, c.age)
              getParameterValues.push(c.name)
            else
              expiry = Math.min(expiry, c.age - timeDiff)
          else
            throw new Error('Unknown configuration type')

      if getParameterValues.length
        taskList.push {device : deviceId, name : 'getParameterValues', parameterNames: getParameterValues, timestamp : new Date()}
      if setParameterValues.length
        taskList.push {device : deviceId, name : 'setParameterValues', parameterValues: setParameterValues, timestamp : new Date()}

      if not presetsHash
        presetsHash = calculatePresetsHash(presets)
        db.memcached.set('presets_hash', presetsHash, expiry - config.PRESETS_TIME_PADDING, (err, res) ->
        )

      db.memcached.set("#{deviceId}_presets_hash", presetsHash, expiry - config.PRESETS_TIME_PADDING, (err, res) ->
        callback(taskList)
      )
    )
  )


accumulateConfigurations = (presets) ->
  maxWeights = {}
  configurations = {}
  for p in presets
    for c in p.configurations
      configurationHash = if c.name? then "#{c.type}_#{c.name}" else c.type

      if not maxWeights[configurationHash]? or p.weight > maxWeights[configurationHash]
        configurations[configurationHash] = c
        maxWeights[configurationHash] = p.weight

  configurationsList = (configurations[c] for c of configurations)
  return configurationsList
