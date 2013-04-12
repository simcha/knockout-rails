#=require jquery
#=require knockout/validations
#=require knockout/validators
#=require knockout/ko_extensions

# Module is taken from Spine.js
moduleKeywords = ['included', 'extended']
class Module
  @include: (obj) ->
    throw('include(obj) requires obj') unless obj
    for key, value of obj when key not in moduleKeywords
      @::[key] = value
    obj.included?.apply(@)
    @

  @extend: (obj) ->
    throw('extend(obj) requires obj') unless obj
    for key, value of obj when key not in moduleKeywords
      @[key] = value
    obj.extended?.apply(@)
    @
    
Events =
  ClassMethods:
    extended: ->
      @include Events.InstanceMethods

    upon: (eventName, callback) ->
      @events ||= {}
      @events[eventName] ||= []
      @events[eventName].push callback
      this # Just to chain it if we need to

  InstanceMethods:
    trigger: (eventName, args...) ->
      cevents = @constructor.events || {}
      chandlers = cevents[eventName] || []
      callback.apply(this, args) for callback in chandlers

      ievents = @events || {}
      ihandlers = ievents[eventName] || []
      callback.apply(this, args) for callback in ihandlers

      this # so that we can chain

    upon: (eventName, callback) ->
      @events ||= {}
      @events[eventName] ||= []
      @events[eventName].push callback
      this # Just to chain it if we need to


Callbacks =
  ClassMethods:
    beforeSave: (callback) -> @upon('beforeSave', callback)
    saveSuccess: (callback) -> @upon('saveSuccess', callback)
    saveValidationError: (callback) -> @upon('saveValidationError', callback) # server validation errors
    saveProcessingError: (callback) -> @upon('saveProcessingError', callback)

    beforeDelete: (callback) -> @upon('beforeDelete', callback)
    deleteError: (callback) -> @upon('deleteError', callback)
    deleteSuccess: (callback) -> @upon('deleteSuccess', callback)


Ajax =
  ClassMethods:
    persistAt: (@controllerName) -> undefined

    getUrl: (model) ->
        @controllerName ||= @name.toLowerCase() + 's'

        collectionUrl = "/#{@controllerName}"
        collectionUrl += "/#{model.id()}" if model?.id()
        collectionUrl

    extended: -> @include Ajax.InstanceMethods

  InstanceMethods:
    toJSON: ->
      # TODO is _destroy sent?
      ko.mapping.toJS @, @__ko_mapping__

    delete: ->
      return false unless @persisted()
      @trigger('beforeDelete') # TODO

      data = {id: @id}

      params =
        type: 'DELETE'
        dataType: 'json'
        beforeSend: (xhr)->
          token = $('meta[name="csrf-token"]').attr('content')
          xhr.setRequestHeader('X-CSRF-Token', token) if token
        url: @constructor.getUrl(@)
        contentType: 'application/json'
        context: this
        processData: false # jQuery tries to serialize to much, including constructor data
        data: JSON.stringify data
        statusCode:
          422: (xhr, status, errorThrown)->
            errorData = JSON.parse xhr.responseText
            console?.debug?("Validation error: ", errorData)
            @updateErrors(errorData.errors)

      $.ajax(params)
        .fail (xhr, status, errorThrown)->
          @trigger('deleteError', errorThrown, xhr, status) if xhr.status == 422
          @trigger('deleteError', errorThrown, xhr, status) if xhr.status != 422

        .done (resp, status, xhr)->
          @id(null)
          @trigger('deleteSuccess', resp, xhr, status)

    save: ->
      return false unless @isValid()

      @trigger('beforeSave') # Consider moving it into the beforeSend or similar

      data = {}
      data[@constructor.name.toLowerCase()] =@toJSON()

      params =
        type: if @persisted() then 'PUT' else 'POST'
        dataType: 'json'
        beforeSend: (xhr)->
          token = $('meta[name="csrf-token"]').attr('content')
          xhr.setRequestHeader('X-CSRF-Token', token) if token
        url: @constructor.getUrl(@)
        contentType: 'application/json'
        context: this
        processData: false # jQuery tries to serialize to much, including constructor data
        data: JSON.stringify data
        statusCode:
          422: (xhr, status, errorThrown)->
            errorData = JSON.parse xhr.responseText
            console?.debug?("Validation error: ", errorData)
            @updateErrors(errorData.errors)

      $.ajax(params)
        .fail (xhr, status, errorThrown)->
          @trigger('saveValidationError', errorThrown, xhr, status) if xhr.status == 422
          @trigger('saveProcessingError', errorThrown, xhr, status) if xhr.status != 422

        .done (resp, status, xhr)->
          if xhr.status == 201 # Created
            @set resp

          @updateErrors {}
          @trigger('saveSuccess', resp, xhr, status)

        #.always (xhr, status) -> console.info "always: ", this

Relations =
  ClassMethods:
    __add_relation: (kind, fld, model) ->
      throw('Target model of relation has to be specified') unless model
      throw('Relation field has to be specified') unless fld

      @fieldsSpecified = true # TODO prefix __
      @fieldNames ||= []
      @__relations ||= []
      @__relations.push kind: kind, fld: fld, model: model

    __get_relation: (fld) ->
      for rel in (@__relations ||= [])
        if rel.fld == fld
          # deferred reference to model
          rel.model = rel.model() if kor.utils.getType(rel.model) == 'function' and Object.keys(rel.model).isEmpty()

          return rel

    has_one: (fld, model) -> @__add_relation 'has_one', fld, model
    belongs_to: (fld, model) -> @__add_relation 'belongs_to', fld, model
    has_many: (fld, model) -> @__add_relation 'has_many', fld, model
    has_and_belongs_to_many: (fld, model) -> @__add_relation 'has_and_belongs_to_many', fld, model

class Model extends Module
  @extend Ajax.ClassMethods
  @extend Events.ClassMethods
  @extend Callbacks.ClassMethods
  @extend Relations.ClassMethods
  @extend ko.Validations.ClassMethods

  @fields: (fieldNames...) ->
    @fieldNames = fieldNames.flatten() # when a single arg is given as an array
    @fieldsSpecified = true

  # TODO Events should not be exposed like this
  # TODO Persisted - czy obsługuje flagę destroyed?
  __ignore:  -> ['errors', 'events', 'persisted']

  # creates mapping and fields
  __initialize: ->
    @errors ||= {}

    mapping =
      ignore: @__ignore()
      include: []
      copy: []
      observe: []
      copiedProperties: {}
      mappedProperties: {}

    for k, v of this
      mapping.ignore.push k unless ko.isObservable(v)

    if @constructor.fieldsSpecified
      # map only fields
      for fld in @constructor.fieldNames
        mapping.include.push fld
        @setField fld, undefined

      for rel in (@constructor.__relations ||= [])
        {fld, kind} = rel
        mapping.include.push fld
        if kind == 'has_many' or kind == 'has_and_belongs_to_many'
          @[fld] = ko.mappedObservableArray()
        else
          @[fld] = ko.observable()
        @errors[fld] = ko.observable()

    mapping.include.push '_destroy'
    @__ko_mapping__ = mapping

  constructor: (json = {}) ->
    me = this
    @__initialize()

    @set json
    @id ||= ko.observable()

    # Overly Heavy, heavy binding to `this`...
    @__ko_mapping__.ignore.exclude('constructor').filter (v)->
        not v.startsWith('_') and Object.isFunction me[v]
      .forEach (fn) ->
        original = me[fn]
        me[fn] = original.bind me
        me._originals ||= {}
        me._originals[fn] = original

    # TODO test if persisted is working on destroyed
    @persisted = ko.dependentObservable -> !!me.id() and not me._destroy
    @enableValidations()

  setField: (fld, value) ->
    # if relation
    if rel = @constructor.__get_relation(fld)
      if rel.kind == 'has_many' or rel.kind == 'has_and_belongs_to_many'
        throw(rel.kind + ' relation needs an array but ' + value + ' was given') unless kor.utils.getType(value) == 'array'

        @[fld] ||= ko.mappedObservableArray()
        value = (new rel.model(elem) for elem in value when elem)
      else if value
        throw(rel.kind + ' relation needs an object but array was given') if kor.utils.getType(value) == 'array'
        value = new rel.model(value)

    @[fld] ||= ko.observable()
    @[fld](value)
    @errors[fld] ||= ko.observable()

    # add to mapping
    if not @constructor.fieldsSpecified
      @__ko_mapping__.include.push fld
    @

  set: (json) ->
    # clear existing values
    for fld, setter of this
      if ko.isObservableArray setter
        setter([])
        @errors[fld](undefined) # TODO create of undefined?
      else if ko.isObservable setter
        setter(undefined)
        @errors[fld](undefined)

    # set values
    for fld in Object.keys(json)
      @setField fld, json[fld]

    # initialize server-side given errors
    if json.errors
      @updateErrors json.errors
    @

  updateErrors: (errorData) ->
    for key, setter of @errors
      field = @errors[key]
      error = errorData[key]
      message = if error and error.join
          error.join(", ")
        else
          error
      setter( message ) if field
    @

  
# Export it all:
ko.Module = Module
ko.Model = Model
ko.Events = Events
